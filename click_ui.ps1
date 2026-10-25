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
#  Just before clicking, the point is verified to belong to XM. UIA still reports
#  the controls of a window that is covered by another one, while a synthetic
#  click always goes to whichever window is on top - so correct coordinates are
#  not enough. When the point belongs to somebody else, XM is raised first (a
#  background process needs AttachThreadInput to be allowed to do that). Without
#  this, a run started from a background console clicked into the covering window
#  and all three steps failed, even though every button was found.
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
#    powershell -NoProfile -ExecutionPolicy Bypass -File click_ui.ps1 -Key enter -Probe
#
#  -Probe answers one question only: "is that control still on screen?"  It
#  locates, prints and exits without settling and without clicking. seer_run.ps1
#  uses it to check that a click actually took effect.
#
#  OUTPUT
#    "found key=<matched key> name=..." then "clicked at (x,y)"
#    The MATCHED KEY is printed because an alias may have matched (e.g. asking
#    for 'enter' may match 'enter_update'), and the caller needs to know which.
#
#    With -Probe: "probe key=<key> found ..." or "probe key=<key> notfound".
#
#  EXIT 0 = clicked (or, with -Probe, found), 3 = nothing matched
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
    # Locate only: report whether the control exists, then exit. Never clicks.
    [switch]$Probe,
    # Force a raise before clicking; the point check does this by itself whenever
    # the click would land on another window.
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
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[StructLayout(LayoutKind.Sequential)] public struct Pt { public int X; public int Y; }
[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Pt p);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
[DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
[DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
[DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder sb, int n);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder sb, int n);
'@
}
[void][Win.CU]::SetProcessDPIAware()

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms

function Get-XMProcList {
    # Compare the plain process name: Get-Process -Name does WILDCARD matching,
    # which a renamed exe ("XM 3564.exe", "XM[1].exe") can break. Get-Process
    # enumerates the same list either way, so this costs nothing extra.
    return @(Get-Process -ErrorAction SilentlyContinue |
             Where-Object { $_.ProcessName -eq $ProcessName })
}

function Get-XMProcess {
    # Prefer a process that Windows thinks has a main window, but do NOT require
    # it. MainWindowHandle is only a hint - input-method hooks hide the real
    # window from it - and reporting "XM did not start" because of that would be
    # plain wrong.
    $list = @(Get-XMProcList)
    if ($list.Count -eq 0) { return $null }
    $withWin = @($list | Where-Object { $_.MainWindowHandle -ne 0 })
    if ($withWin.Count -gt 0) { return $withWin[0] }
    return $list[0]
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

            # Skip the log box. Its ClassName is 'Edit' and its text mentions
            # words like "login" / "server login successful" / "start", so the
            # "name contains the label" rule below reports a button that is no
            # longer on screen - and seer_run.ps1 then believes the click failed
            # and presses the same button again.
            $cls = ''
            try { $cls = [string]$e.Current.ClassName } catch { $cls = '' }
            if ($cls -eq 'Edit') { continue }

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
    $procs = @(Get-XMProcList)
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

function Get-XMGameWindow {
    # Which window is the game itself?
    #
    # Process.MainWindowHandle CANNOT be trusted here. Input-method DLLs (iFlytek
    # among them) load into the XM process and create their OWN top-level windows
    # there. On this machine Windows reported MainWindowHandle as a window of
    # class "iFLY_notify_window" - a 628x100 notification strip. Restoring and
    # pinning THAT window is what drew a black band just above the taskbar, and
    # it also meant "raise XM" never really raised the game.
    #
    # The game window is the visible top-level window of class "WTWindow". When
    # several exist the longest title wins (the game window is "XM Seer...", the
    # overlay window has a short title) and a non-minimised window wins over a
    # minimised one. Returns [IntPtr]::Zero when there is none - never fall back
    # to MainWindowHandle, that fallback is exactly the bug.
    $best = [IntPtr]::Zero
    $bestScore = -1
    foreach ($h in @(Get-XMWindowsAll)) {
        try {
            if ([Win.CU]::GetAncestor($h, 2) -ne $h) { continue }        # top-level only
            if (-not [Win.CU]::IsWindowVisible($h)) { continue }
            $cn = New-Object System.Text.StringBuilder 256
            [void][Win.CU]::GetClassNameW($h, $cn, 256)
            if ($cn.ToString() -ne 'WTWindow') { continue }
            $tb = New-Object System.Text.StringBuilder 512
            [void][Win.CU]::GetWindowTextW($h, $tb, 512)
            $score = $tb.ToString().Length * 1000
            if (-not [Win.CU]::IsIconic($h)) { $score += 500 }
            if ($score -gt $bestScore) { $bestScore = $score; $best = $h }
        } catch { }
    }
    return $best
}

function Raised-XM {
    # Bring the window to the front so that a synthetic click really lands on it.
    # Two separate problems are handled here:
    #
    #   * a window that sits BEHIND another one still exposes its controls to
    #     UIA, so the coordinates can be perfectly correct while the click goes
    #     to whichever window is on top of it;
    #   * a window started by a background process is not allowed to steal the
    #     foreground, so a plain SetForegroundWindow is silently ignored.
    #
    # Attaching to the foreground thread's input queue works around the second
    # one. The first one is handled by Set-XMTopmost, and only when this function
    # turns out not to be enough.
    param([IntPtr]$Hwnd)
    if ([Win.CU]::IsIconic($Hwnd)) { [void][Win.CU]::ShowWindow($Hwnd, 9) }   # SW_RESTORE

    $fg = [Win.CU]::GetForegroundWindow()
    $fgPid = 0
    $fgThread = 0
    if ($fg -ne [IntPtr]::Zero) { $fgThread = [Win.CU]::GetWindowThreadProcessId($fg, [ref]$fgPid) }
    $myThread = [Win.CU]::GetCurrentThreadId()

    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $myThread) {
        $attached = [Win.CU]::AttachThreadInput($myThread, $fgThread, $true)
    }
    [void][Win.CU]::BringWindowToTop($Hwnd)
    [void][Win.CU]::SetForegroundWindow($Hwnd)
    if ($attached) { [void][Win.CU]::AttachThreadInput($myThread, $fgThread, $false) }

    Start-Sleep -Milliseconds 400
}

function Set-XMTopmost {
    # Pin the window above EVERY other window (HWND_TOPMOST), or release it.
    #
    # Windows refuses to hand the foreground to a background process, but it does
    # allow the Z order to be changed - so this is the reliable way to make a
    # synthetic click land on XM when another window covers it. It is switched on
    # only for the duration of the click and always switched off afterwards.
    param([IntPtr]$Hwnd, [bool]$On)
    $swp = 0x0001 -bor 0x0002 -bor 0x0010          # NOSIZE | NOMOVE | NOACTIVATE
    $after = -1                                     # HWND_TOPMOST
    if (-not $On) { $after = -2 }                   # HWND_NOTOPMOST
    [void][Win.CU]::SetWindowPos($Hwnd, [IntPtr]$after, 0, 0, 0, 0, $swp)
}

function Test-Clickable {
    # Does the window that owns this screen point belong to the target process?
    # WindowFromPoint returns the deepest child, so the root ancestor is checked.
    param([int]$X, [int]$Y, [int[]]$Pids)
    # WindowFromPoint takes a POINT BY VALUE. Declaring it as (int, int) makes it
    # read the two numbers from two different registers and return nonsense.
    $pt = New-Object 'Win.CU+Pt'
    $pt.X = $X
    $pt.Y = $Y
    $at = [Win.CU]::WindowFromPoint($pt)
    if ($at -eq [IntPtr]::Zero) { return $false }
    $root = [Win.CU]::GetAncestor($at, 2)          # GA_ROOT
    if ($root -eq [IntPtr]::Zero) { $root = $at }
    $ownerPid = 0
    [void][Win.CU]::GetWindowThreadProcessId($root, [ref]$ownerPid)
    foreach ($p in $Pids) { if ([int]$p -eq [int]$ownerPid) { return $true } }
    return $false
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
            $gw = Get-XMGameWindow
            if ($gw -ne [IntPtr]::Zero) { Raised-XM $gw }
            $raisedAlready = $true
            $hit = Find-ButtonEverywhere
            if ($null -ne $hit) { break }
        }
    }

    if (-not $Wait) { break }

    if ((Get-Date) -gt $deadline) {
        if (-not $sawProc) {
            Write-Host ($ProcessName + ' did not start within ' + $TimeoutSeconds + 's (' + $attempts + ' polls)')
        } else {
            Write-Host ('no matching control for key "' + $Key + '" after ' + $TimeoutSeconds +
                        's (' + $attempts + ' polls)')
        }
        exit 3
    }
    Start-Sleep -Milliseconds 500
}

if ($null -eq $hit) {
    if ($Probe) { Write-Host ('probe key=' + $Key + ' notfound') }
    else { Write-Host ('no matching control for key "' + $Key + '"') }
    exit 3
}

if ($Probe) {
    Write-Host ('probe key=' + $hit.Key + ' found name="' + $hit.Name + '" ' + $hit.W + 'x' + $hit.H +
                ' center=(' + $hit.X + ',' + $hit.Y + ') enabled=' + $hit.Enabled +
                ' rank=' + $hit.Rank + ' after ' + $attempts + ' poll(s)')
    exit 0
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

# ---- make sure the click can actually land on XM ---------------------------
#
# UIA reports the controls of covered windows too, so sending a click to the
# right coordinates is not enough: whatever window is on TOP receives it. The
# point is therefore checked first, XM is raised when it belongs to somebody
# else, and the control is located again because raising can move the window.
$procs = @(Get-XMProcList | Where-Object { $_.MainWindowHandle -ne 0 })
$pids = @($procs | ForEach-Object { [int]$_.Id })
$gameHwnd = Get-XMGameWindow

if ($BringToFront -and $procs.Count -gt 0 -and $gameHwnd -ne [IntPtr]::Zero) {
    Write-Host 'BringToFront: raising the window before clicking'
    Raised-XM $gameHwnd
    $again = Find-ButtonEverywhere
    if ($null -ne $again) { $hit = $again }
}

$pinnedTopmost = $false
for ($guard = 1; $guard -le 3; $guard++) {
    if ($pids.Count -eq 0) { break }
    if (Test-Clickable -X $hit.X -Y $hit.Y -Pids $pids) { break }
    Write-Host ('point (' + $hit.X + ',' + $hit.Y + ') belongs to another window; raising ' +
                $ProcessName + ' (' + $guard + '/3)')
    if ($gameHwnd -ne [IntPtr]::Zero) { Raised-XM $gameHwnd }
    $again = Find-ButtonEverywhere
    if ($null -ne $again) { $hit = $again }
}

if ($pids.Count -gt 0 -and -not (Test-Clickable -X $hit.X -Y $hit.Y -Pids $pids)) {
    Write-Host ('point (' + $hit.X + ',' + $hit.Y + ') is still covered; floating ' +
                $ProcessName + ' above the other windows for the click')
    if ($gameHwnd -ne [IntPtr]::Zero) { Set-XMTopmost -Hwnd $gameHwnd -On $true }
    $pinnedTopmost = $true
    Start-Sleep -Milliseconds 300
    $again = Find-ButtonEverywhere
    if ($null -ne $again) { $hit = $again }
    if (-not (Test-Clickable -X $hit.X -Y $hit.Y -Pids $pids)) {
        Write-Host ('WARNING: point (' + $hit.X + ',' + $hit.Y + ') still belongs to another window; clicking anyway')
    }
}

[System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($hit.X, $hit.Y)
Start-Sleep -Milliseconds 150
[Win.CU]::mouse_event(0x0002, 0, 0, 0, 0)
Start-Sleep -Milliseconds 150
[Win.CU]::mouse_event(0x0004, 0, 0, 0, 0)
Write-Host ('clicked at (' + $hit.X + ',' + $hit.Y + ')')

if ($pinnedTopmost) {
    Start-Sleep -Milliseconds 200
    if ($gameHwnd -ne [IntPtr]::Zero) { Set-XMTopmost -Hwnd $gameHwnd -On $false }
    Write-Host 'topmost pin released'
}
exit 0
