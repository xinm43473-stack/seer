# =============================================================================
#  click_ui.ps1 -- find an XM button by NAME (UI Automation) and click it.
#
#  Two modes:
#    -Wait : poll until the control exists (and, for 'start', is ENABLED), then
#            wait -SettleSeconds (default 3) and click.
#    (no -Wait) : locate once and click.
#
#  Click technique is identical to the original batch: Cursor.Position plus
#  user32 mouse_event with 150 ms between down and up. Only the coordinates now
#  come from the live control instead of hard-coded pixels.
#
#  Keys are passed as ASCII words, NOT Chinese text: PowerShell 5.1 encodes
#  native argv with the ANSI code page, so Chinese arguments would be mangled.
#  The Chinese labels are built here from Unicode code points instead.
#
#  This process declares itself DPI-AWARE on purpose: UIA hands out PHYSICAL
#  pixels and a DPI-aware process sets the cursor in physical pixels too, so no
#  conversion is needed. (seer_run.ps1 stays DPI-unaware for the log reading.)
#
#  PURE ASCII.
#
#  USAGE
#    powershell -NoProfile -ExecutionPolicy Bypass -File click_ui.ps1 -Key start -Wait -TimeoutSeconds 300
#    powershell -NoProfile -ExecutionPolicy Bypass -File click_ui.ps1 -Key enter -DryRun
#
#  OUTPUT
#    "found key=<matched key> name=..." then "clicked at (x,y)"
#    The MATCHED KEY is printed because an alias may have matched (e.g. asking
#    for 'enter' may match 'enter_update'), and the caller needs to know which.
#
#  EXIT 0 = clicked, 3 = nothing matched (caller decides what to do)
# =============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('enter', 'login', 'start')]
    [string]$Key,
    [switch]$Wait,
    [int]$TimeoutSeconds = 180,
    [int]$SettleSeconds = 3,
    [switch]$DryRun,
    [switch]$BringToFront,
    # Testing hook: match against another process's window (default XM).
    [string]$ProcessName = 'XM'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

function U { param([int[]]$Codes) return (-join ($Codes | ForEach-Object { [char]$_ })) }

# ---------------------------------------------------------------------------
#  Label table. The FIRST entry is the preferred button; later entries are
#  fallbacks that are only used when the preferred one does not exist.
#
#  Several entries carry flexible FRAGMENTS as well, because the exact wording
#  of XM's update prompt is not known for certain. A fragment matches a
#  substring anywhere, so it survives different punctuation/wording as long as
#  the essential words are present.
# ---------------------------------------------------------------------------


$L_ENTER = U @(0x8FDB,0x5165,0x8131,0x673A)

$L_CONT  = U @(0x7EE7,0x7EED,0x4F7F,0x7528)

$L_THISVER = U @(0x4F7F,0x7528,0x8BE5,0x7248,0x672C)

$L_UPDATE = U @(0x7EE7,0x7EED,0x4F7F,0x7528,0x8BE5,0x7248,0x672C)


$L_LOGIN  = U @(0x767B,0x9646)
$L_LOGIN2 = U @(0x767B,0x5F55)

$L_START  = U @(0x5F00,0x59CB)

$labelTable = @{
    'enter' = @(
        [pscustomobject]@{ Key = 'enter';        Label = $L_ENTER;  Frags = @() }
        [pscustomobject]@{ Key = 'enter_update'; Label = $L_UPDATE; Frags = @($L_CONT, $L_THISVER) }
    )
    'login' = @(
        [pscustomobject]@{ Key = 'login'; Label = $L_LOGIN;  Frags = @() }
        [pscustomobject]@{ Key = 'login'; Label = $L_LOGIN2; Frags = @() }
    )
    'start' = @(
        [pscustomobject]@{ Key = 'start'; Label = $L_START; Frags = @() }
    )
}
$labelEntries = $labelTable[$Key]

# U+FFFC: UIA object-replacement character, must never be treated as a name
$repl = [string][char]0xFFFC

if (-not ('Win.CU' -as [type])) {
    Add-Type -Namespace 'Win' -Name 'CU' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, uint e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
'@
}
[void][Win.CU]::SetProcessDPIAware()

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

function Get-XMProcess {
    return (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
}

function Find-Button {
    # Best match in one window.
    #
    # Ranking (lower wins), so the PREFERRED button always beats a fallback even
    # if the fallback is smaller/higher in the tree:
    #     0 = exact label text
    #     1 = name contains the label
    #     2 + i = name contains fragment #i
    # Within the same rank, the smallest control wins (the real button, not the
    # container around it).
    param([IntPtr]$Hwnd)

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    } catch { return $null }
    if ($null -eq $root) { return $null }
    try {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                             [System.Windows.Automation.Condition]::TrueCondition)
    } catch { return $null }

    $best = $null
    for ($i = 0; $i -lt $all.Count; $i++) {
        $e = $all.Item($i)
        try {
            $raw = $e.Current.Name
            if (-not $raw) { continue }
            $nm = ([string]$raw).Replace($repl, '').Trim()
            if ($nm.Length -eq 0) { continue }

            $r = $e.Current.BoundingRectangle
            if ($r.Width -le 1 -or $r.Height -le 1) { continue }
            if ($r.X -lt -100000 -or $r.Y -lt -100000) { continue }

            # find this element's rank across all label entries
            $rank = -1
            $mkey = ''
            for ($k = 0; $k -lt $labelEntries.Count; $k++) {
                $le = $labelEntries[$k]
                if ($le.Label -and $nm -eq $le.Label) { $rank = 0; $mkey = $le.Key; break }
                if ($le.Label -and $nm.Contains($le.Label)) { $rank = 1; $mkey = $le.Key; break }
                for ($f = 0; $f -lt $le.Frags.Count; $f++) {
                    if ($nm.Contains($le.Frags[$f])) {
                        $rank = 2 + $f; $mkey = $le.Key; break
                    }
                }
                if ($rank -ge 0) { break }
            }
            if ($rank -lt 0) { continue }

            $enabled = $true
            try { $enabled = [bool]$e.Current.IsEnabled } catch { $enabled = $true }
            if ($Key -eq 'start' -and -not $enabled) { continue }

            $area = $r.Width * $r.Height
            if ($null -eq $best -or
                $rank -lt $best.Rank -or
                ($rank -eq $best.Rank -and $area -lt $best.Area)) {
                $best = [pscustomobject]@{
                    Key     = $mkey
                    Rank    = $rank
                    Name    = $nm
                    X       = [int]($r.X + $r.Width / 2)
                    Y       = [int]($r.Y + $r.Height / 2)
                    W       = [int]$r.Width
                    H       = [int]$r.Height
                    Area    = $area
                    Enabled = $enabled
                }
            }
        } catch {}
    }
    return $best
}

function Find-ButtonEverywhere {
    # Best match across every XM-owned window (top-level + children).
    $best = $null
    foreach ($h in (Get-XMWindowsAll)) {
        $b = Find-Button -Hwnd $h
        if ($null -eq $b) { continue }
        if ($null -eq $best -or
            $b.Rank -lt $best.Rank -or
            ($b.Rank -eq $best.Rank -and $b.Area -lt $best.Area)) {
            $best = $b
        }
    }
    return $best
}

if (-not ('Win.CUW' -as [type])) {
    Add-Type -Namespace 'Win' -Name 'CUW' -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")]
static extern bool EnumWindows(EnumProc cb, IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")]
static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")]
static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);

public static IntPtr[] WindowsOfPids(int[] pids) {
    System.Collections.Generic.List<IntPtr> found = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
        uint pid; GetWindowThreadProcessId(h, out pid);
        for (int i = 0; i < pids.Length; i++) { if ((int)pid == pids[i]) { found.Add(h); break; } }
        return true;
    }, IntPtr.Zero);
    return found.ToArray();
}
public static IntPtr[] ChildrenOf(IntPtr[] tops) {
    System.Collections.Generic.List<IntPtr> found = new System.Collections.Generic.List<IntPtr>();
    for (int i = 0; i < tops.Length; i++) {
        EnumChildWindows(tops[i], delegate(IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
    }
    return found.ToArray();
}
'@
}

function Get-XMWindowsAll {
    # Top-level windows owned by XM plus all their children.
    $procs = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }
    $pids = @($procs | ForEach-Object { [int]$_.Id })
    try {
        $tops = @([Win.CUW]::WindowsOfPids($pids))
        if ($tops.Count -eq 0) { return @() }
        $kids = @([Win.CUW]::ChildrenOf($tops))
        $out = New-Object System.Collections.ArrayList
        foreach ($h in $tops) { [void]$out.Add($h) }
        foreach ($h in $kids) { if (-not $out.Contains($h)) { [void]$out.Add($h) } }
        return @($out.ToArray())
    } catch { return @() }
}

function Raised-XM {
    param([IntPtr]$Hwnd)
    [void][Win.CU]::ShowWindow($Hwnd, 9)          # SW_RESTORE
    [void][Win.CU]::SetForegroundWindow($Hwnd)
    Start-Sleep -Milliseconds 400
}

# ---- locate (optionally waiting for readiness) ------------------------------
#
# The process/window check lives INSIDE the loop on purpose: seer_run.ps1 starts
# XM.exe and immediately calls this script, so at that instant XM's window does
# not exist yet. Failing fast here made step 1 abort within seconds.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$hit = $null
$raisedAlready = $false
$attempts = 0
$sawProc = $false

while ($true) {
    $attempts++
    $proc = Get-XMProcess
    if ($null -ne $proc) {
        $sawProc = $true
        $hit = Find-ButtonEverywhere
        if ($null -ne $hit) { break }

        # A hidden/behind window can drop its controls from the automation tree;
        # raise it once and look again.
        if (-not $raisedAlready) {
            Raised-XM $proc.MainWindowHandle
            $raisedAlready = $true
            $hit = Find-ButtonEverywhere
            if ($null -ne $hit) { break }
        }
    }

    if (-not $Wait) { break }

    if ((Get-Date) -gt $deadline) {
        if (-not $sawProc) {
            Write-Host ('XM.exe did not start within ' + $TimeoutSeconds + 's (' + $attempts + ' polls)')
        } else {
            Write-Host ('no matching control for key "' + $Key + '" after ' + $TimeoutSeconds +
                        's (' + $attempts + ' polls)')
        }
        exit 3
    }
    Start-Sleep -Milliseconds 500
}

if ($null -eq $hit) {
    Write-Host ('no matching control for key "' + $Key + '"')
    exit 3
}

Write-Host ('found key=' + $hit.Key + ' name="' + $hit.Name + '" ' + $hit.W + 'x' + $hit.H +
            ' center=(' + $hit.X + ',' + $hit.Y + ') enabled=' + $hit.Enabled +
            ' rank=' + $hit.Rank + ' after ' + $attempts + ' poll(s)')

# ---- settle: let the freshly drawn UI finish before clicking ----------------
if ($SettleSeconds -gt 0) {
    Write-Host ('settling ' + $SettleSeconds + 's before clicking')
    Start-Sleep -Seconds $SettleSeconds
}

if ($DryRun) { Write-Host 'DryRun: not clicking'; exit 0 }

[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($hit.X, $hit.Y)
Start-Sleep -Milliseconds 150
[Win.CU]::mouse_event(0x0002, 0, 0, 0, 0)
Start-Sleep -Milliseconds 150
[Win.CU]::mouse_event(0x0004, 0, 0, 0, 0)
Write-Host ('clicked at (' + $hit.X + ',' + $hit.Y + ')')
exit 0
