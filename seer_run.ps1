# =============================================================================
#  seer_run.ps1  --  XM launch flow + log detection + WeCom notifications
#
#  Replaces the fragile batch control flow with something testable.
#  Called by seer.bat (which stays as a double-clickable launcher).
#
#  FLOW  (three clicks, each performed ONCE - same timing as the original
#         working seer.bat; there is deliberately NO retry loop)
#    1) start XM.exe, wait 30s, click (760,460) "enter offline mode"
#       wait 60s, click (180,180) "login", wait 60s
#    2) snapshot the log, click (890,590) "start", then poll immediately
#    3) start line appears      -> push that exact log line
#       or nothing within 60s   -> push the failure message
#    4) completion line appears -> push that exact log line
#       or nothing within 4h    -> push the timeout message
#
#  WHY NO RETRY: if the first "start" click does not take effect, clicking the
#  same pixel again lands on exactly the same dead spot (observed in the 21:16
#  run: 1/3, 2/3, 3/3 all clicked (890,590) and the log never moved).
#
#  WHY POWERSHELL ONLY (no Python)
#    * reading XM's log needs UI Automation (PowerShell can do it unelevated)
#    * sending the WeCom webhook is a plain HTTPS POST, done here with
#      Invoke-RestMethod and an HttpClient fallback.
#    Earlier versions shelled out to send_wecom.py because HTTPS appeared broken
#    (Schannel "No credentials are available in the security package"). That was
#    a sandbox artefact, not this machine: Invoke-RestMethod works fine here, so
#    the Python dependency has been dropped.
#    Message text still travels in the request BODY as UTF-8 bytes, never
#    through argv, so the Chinese content is never mangled.
#
#  This file is PURE ASCII on purpose (PowerShell 5.1 mis-decodes UTF-8 sources
#  without a BOM). Chinese strings are built from Unicode code points.
# =============================================================================

# =============================================================================
#  FEATURES
#    * clicks XM's buttons by NAME through UI Automation - no hard-coded pixels,
#      so it survives window moves and DPI changes
#    * if "enter offline mode" is missing, falls back to the "a new version is
#      available / keep using this version" prompt, clicks through it and pushes
#      a notification saying so
#    * start notification is trimmed to [hh:mm:ss]:start executing
#    * completion is checked every 5 minutes (-DonePollSeconds) by reading only
#      the NEWEST log line, instead of snapshotting the whole log every second
#    * -ReturnToDesktop minimises XM and shows the desktop once the start line is
#      detected (still reads the log through UIA while minimised)
#    * WeCom webhook sent with the .NET HTTP stack - no Python needed
#    * the robot key lives in wecom_key.txt and the XM path in xm_path.txt, so
#      neither has to be edited inside the script
#    * every file is pure ASCII (PowerShell 5.1 mis-decodes BOM-less UTF-8
#      sources, so Chinese strings are built from Unicode code points)
# =============================================================================

[CmdletBinding()]
param(
    # How long to wait for each button to become available. Buttons are located
    # through UI Automation and clicked as soon as they are ready, so these are
    # upper bounds, not fixed sleeps.
    [int]$EnterTimeoutSeconds   = 180,      # wait for the "enter offline mode" button
    [int]$LoginTimeoutSeconds   = 180,      # wait for the "login" button
    [int]$StartTimeoutSeconds   = 300,      # wait for "start" to be ENABLED
    [int]$SettleSeconds         = 3,        # pause once ready, before clicking
    # Wait for the start line. Measured: after clicking "start", XM needs roughly
    # 40-60s before the log box appears and fills in, so 60s was too tight and the
    # detection window closed right before the log became readable.
    [int]$DetectWindowSeconds   = 300,      # wait for the start log line
    [int]$DoneTimeoutSeconds    = 14400,    # wait for the completion log line (4h)
    # The completion check is deliberately slow: a long run can go for hours,
    # and polling the full log every second wastes memory/CPU for nothing.
    [int]$DonePollSeconds       = 300,      # poll the newest line every 5 minutes

    # Pixel fallbacks, used ONLY with -UseFixedCoords (original batch behaviour).
    [int]$EnterX = 760, [int]$EnterY = 460,
    [int]$LoginX = 180, [int]$LoginY = 180,
    [int]$StartX = 890, [int]$StartY = 590,

    [switch]$UseFixedCoords,         # click fixed pixels instead of locating the button
    [switch]$ReturnToDesktop,        # on detecting the start line, minimise XM and show the desktop
    # Webhook override. Leave empty to use wecom_key.txt (next to this script),
    # falling back to the built-in key baked into $DefaultWebhook below.
    [string]$Webhook = '',
    # XM.exe override. Leave empty to use xm_path.txt, then the built-in
    # path below. Only needed if XM lives somewhere else.
    [string]$XmExeOverride = '',
    [switch]$ScanAllProcesses,       # slow desktop-wide fallback search (off by default)
    [switch]$AllowExisting,          # for self-testing only
    [switch]$SkipLaunch,             # for self-testing only
    [switch]$NoSend,                 # detect only
    [string]$LogProviderPath = ''    # for self-testing: script that defines Get-XMLogText
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# IMPORTANT: do NOT call SetProcessDPIAware() here.
# This machine runs two displays at 200% scaling. The original working batch
# used a DPI-UNAWARE PowerShell with [Windows.Forms.Cursor]::Position, so its
# (760,460)/(180,180)/(890,590) are *logical* coordinates. Declaring DPI
# awareness switches the same numbers to *physical* pixels and every click
# lands in the wrong place. We therefore keep the process DPI-unaware and use
# exactly the same API the working batch used.

function U { param([int[]]$Codes) return (-join ($Codes | ForEach-Object { [char]$_ })) }

# ---- Chinese strings (code points) ------------------------------------------
# U+5F00 U+59CB U+6267 U+884C
$P_START     = U @(0x5F00,0x59CB,0x6267,0x884C)
# U+81EA U+5B9A U+4E49 U+9B54 U+6CD5  -- note: NO bracket here, because it is
# always combined with $M_START_OPEN ("start executing [") which supplies it.
$P_CUSTOM    = U @(0x81EA,0x5B9A,0x4E49,0x9B54,0x6CD5)
# U+9009 U+62E9 U+4EFB U+52A1 U+5DF2 U+6267 U+884C U+5B8C U+6BD5 U+007E
$P_DONE      = U @(0x9009,0x62E9,0x4EFB,0x52A1,0x5DF2,0x6267,0x884C,0x5B8C,0x6BD5,0x7E)
# U+4EFB U+52A1 U+5931 U+8D25
$P_FAILMSG   = U @(0x4EFB,0x52A1,0x5931,0x8D25)
# Notification for the "a newer version is available" prompt:
#   U+6709 U+65B0 U+7248 U+672C         -> a new version is available
#   U+FF0C                              -> fullwidth comma
#   U+7EE7 U+7EED U+4F7F U+7528 U+8BE5 U+7248 U+672C -> continue with this version
$P_UPDATE_NOTIFY = (U @(0x6709,0x65B0,0x7248,0x672C)) + (U @(0xFF0C)) +
                   (U @(0x7EE7,0x7EED,0x4F7F,0x7528,0x8BE5,0x7248,0x672C))
# U+4EFB U+52A1 U+6267 U+884C U+8D85 U+65F6 U+FF0C U+672A U+68C0 U+6D4B U+5230 U+5B8C U+6210 U+63D0 U+793A
$P_TIMEMSG   = U @(0x4EFB,0x52A1,0x6267,0x884C,0x8D85,0x65F6,0xFF0C,0x672A,0x68C0,
                   0x6D4B,0x5230,0x5B8C,0x6210,0x63D0,0x793A)

# ---- Chinese exit-code summary (printed here, not by seer.bat) --------------
# seer.bat is pure ASCII on purpose: cmd.exe parses .bat files with the ANSI
# code page before chcp takes effect, so Chinese text in a .bat gets tokenised
# into garbage commands. Printing the summary from PowerShell avoids that.
$P_EXIT = @{
    0 = (U @(0x5DF2,0x63A8,0x9001,0x0020,0x5F00,0x59CB,0x6267,0x884C,0x0020,0x002B,0x0020,0x4EFB,0x52A1,0x5B8C,0x6210))
    1 = (U @(0x63A8,0x9001,0x5931,0x8D25,0xFF0C,0x8BE6,0x89C1,0x0020,0x0073,0x0065,0x0065,0x0072,0x005F,0x0077,0x0061,0x0074,0x0063,0x0068,0x002E,0x006C,0x006F,0x0067))
    2 = (U @(0x6CA1,0x68C0,0x6D4B,0x5230,0x5F00,0x59CB,0x6267,0x884C,0x6807,0x8BB0,0xFF0C,0x5DF2,0x63A8,0x9001,0x0020,0x4EFB,0x52A1,0x5931,0x8D25))
    3 = (U @(0x7B49,0x5F85,0x5B8C,0x6210,0x6807,0x8BB0,0x8D85,0x65F6))
    4 = (U @(0x8FDB,0x5165,0x8131,0x673A,0x6309,0x94AE,0x59CB,0x7EC8,0x4E0D,0x53EF,0x70B9,0x51FB))
    5 = (U @(0x767B,0x9646,0x6309,0x94AE,0x59CB,0x7EC8,0x4E0D,0x53EF,0x70B9,0x51FB))
    6 = (U @(0x5F00,0x59CB,0x6309,0x94AE,0x59CB,0x7EC8,0x672A,0x53D8,0x4E3A,0x53EF,0x70B9,0x51FB))
    7 = (U @(0x672A,0x914D,0x7F6E,0x4F01,0x4E1A,0x5FAE,0x4FE1,0x0020,0x006B,0x0065,0x0079))
    9 = (U @(0x627E,0x4E0D,0x5230,0x0020,0x0058,0x004D,0x002E,0x0065,0x0078,0x0065))
}
$P_EXIT_TITLE = U @(0x6D41,0x7A0B,0x7ED3,0x675F,0xFF0C,0x9000,0x51FA,0x7801,0x0020)
$P_EXIT_UNK   = U @(0x672A,0x77E5,0x9000,0x51FA,0x7801)

function Write-ExitSummary {
    param([int]$Code)
    $desc = if ($P_EXIT.ContainsKey($Code)) { $P_EXIT[$Code] } else { $P_EXIT_UNK }
    Write-Host ''
    Write-Host ('---- ' + $P_EXIT_TITLE + $Code + ' ----')
    Write-Host ('  ' + $Code + ' = ' + $desc)
    Write-Host ''
}
# "Flash" and "FLash" (XM writes "FLash" in this log line) and "Unity"
$P_FLASH     = U @(0x0046,0x006C,0x0061,0x0073,0x0068)
$P_FLASH2    = U @(0x0046,0x004C,0x0061,0x0073,0x0068)
# U+65E5 U+5E38 U+7B7E U+5230 U+0026 U+9053 U+5177 U+5151 U+6362
# (daily sign-in & item exchange - the list this run starts with)
$P_DAILY     = U @(0x65E5,0x5E38,0x7B7E,0x5230,0x0026,0x9053,0x5177,0x5151,0x6362)
$P_UNITY     = U @(0x0055,0x006E,0x0069,0x0074,0x0079)

$M_START_FULL  = $M_START_OPEN + $P_CUSTOM + '-' + $P_FLASH + ']'
$M_START_FULL2 = $M_START_OPEN + $P_CUSTOM + '-' + $P_FLASH2 + ']'
$M_START_LOOSE = $P_START + $P_CUSTOM
$M_UNITY_LOOSE = $M_START_OPEN + $P_CUSTOM + '-' + $P_UNITY + ']'

$M_MAGIC_HEADER = $M_START_OPEN + $P_CUSTOM
# The line this build waits for:
#   [hh:mm:ss] + start executing [ daily sign-in & item exchange ]

# different task list, and the guard in Test-StartLine uses it to REJECT
# custom-magic lines; including it here made the real target unmatchable.
$M_START_DAILY = $P_START + '[' + $P_DAILY + ']'

$M_START_OPEN  = $P_START + '['

# ---- paths ------------------------------------------------------------------
$Bin     = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFile = Join-Path $Bin 'seer_watch.log'

# XM.exe location (soft-coded). Where it comes from, highest priority first:
#   1. -XmExeOverride "D:\path\XM.exe"     (command line)
#   2. xm_path.txt next to this script       (edit the file, no code change)
#   3. $DefaultXmExe below                   (built-in fallback)
# XM keeps its data (ini\ config, caches) NEXT TO ITS OWN EXE, so pointing this
# at another folder is enough - the working directory does not matter.
$DefaultXmExe = 'D:\wenjianjia\xm\XM.exe'
$XmPathFile   = Join-Path $Bin 'xm_path.txt'
$XmExe        = $DefaultXmExe
$XmSource     = 'built-in default'

function Resolve-XmPath {
    # Tidy up a user-supplied path: strip quotes/spaces, then accept either a
    # full path to XM.exe or just the folder that contains it.
    param([string]$Value)
    if (-not $Value) { return '' }
    $v = $Value.Trim().Trim('"').Trim("'")
    if ($v.Length -eq 0) { return '' }
    if ($v -match '\.exe$') { return $v }
    return (Join-Path $v 'XM.exe')
}

if ($XmExeOverride) {
    $XmExe = Resolve-XmPath -Value $XmExeOverride
    $XmSource = '-XmExeOverride argument'
} elseif (Test-Path -LiteralPath $XmPathFile) {
    $raw = ''
    try { $raw = (Get-Content -LiteralPath $XmPathFile -Raw -ErrorAction Stop) } catch {}
    $line = ($raw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1)
    $resolved = Resolve-XmPath -Value $line
    if ($resolved) {
        $XmExe = $resolved
        $XmSource = 'xm_path.txt'
    } else {
        $XmSource = 'built-in default (xm_path.txt was empty)'
    }
}

# ---- WeCom webhook (soft-coded) ---------------------------------------------
#
# Where the key comes from, highest priority first:
#   1. -Webhook "https://...key=..."            (command line)
#   2. wecom_key.txt next to this script        (just paste the key, editable)
#   3. $DefaultWebhook below                    (built-in fallback)
#
# So to change the robot you can simply edit wecom_key.txt - no need to touch
# this script. The send itself is a plain HTTPS POST with the .NET stack; the
# message text travels in the REQUEST BODY as UTF-8 bytes, never through argv
# (PowerShell 5.1 encodes native argv with the ANSI code page -> mojibake).
# No key is shipped with this repository on purpose, so a leaked copy of the
# script can never post into somebody's group. Put your own key in
# wecom_key.txt next to this script (or pass -Webhook).
$DefaultWebhook = ''
$WebhookKeyFile = Join-Path $Bin 'wecom_key.txt'
$WebhookUrl     = $DefaultWebhook
$WebhookSource  = 'built-in default'

function Resolve-Webhook {
    # Turn whatever is in the key file / -Webhook into a full webhook URL.
    param([string]$Value)
    if (-not $Value) { return '' }
    $v = $Value.Trim().Trim('"').Trim("'")
    if ($v.Length -eq 0) { return '' }
    if ($v -like 'http*') { return $v }
    # A bare key, optionally prefixed with "key="
    if ($v.StartsWith('key=')) { $v = $v.Substring(4) }
    return ('https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=' + $v)
}

if ($Webhook) {
    $WebhookUrl = Resolve-Webhook -Value $Webhook
    $WebhookSource = '-Webhook argument'
} elseif (Test-Path -LiteralPath $WebhookKeyFile) {
    # Read as ASCII/UTF8; the key is ASCII so the PS 5.1 encoding quirk cannot bite.
    $raw = ''
    try { $raw = (Get-Content -LiteralPath $WebhookKeyFile -Raw -ErrorAction Stop) } catch {}
    # keep only the first non-comment, non-empty line
    $line = ($raw -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 -and -not $_.Trim().StartsWith('#') } | Select-Object -First 1)
    $resolved = Resolve-Webhook -Value $line
    if ($resolved) {
        $WebhookUrl = $resolved
        $WebhookSource = 'wecom_key.txt'
    } else {
        $WebhookSource = 'built-in default (wecom_key.txt was empty)'
    }
}

# Never print the key itself, only its tail, so logs stay shareable.
$keyTail = ''
if ($WebhookUrl -match 'key=([^&]+)') {
    $k = $Matches[1]
    if ($k.Length -gt 8) { $keyTail = '...' + $k.Substring($k.Length - 8) } else { $keyTail = '(short)' }
}
$WebhookDisplay = ($WebhookUrl -replace 'key=[^&]+', ('key=' + $keyTail))

function Write-Log {
    param([string]$Text, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Text
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

# ---- sending ----------------------------------------------------------------
function Invoke-WebhookOnce {
    # One HTTP POST. Returns $true on errcode 0.
    param([string]$Payload)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Payload)

    # Preferred: Invoke-RestMethod. We pass UTF-8 bytes so the Chinese content
    # is not re-encoded by the default ANSI content-type handling.
    try {
        $resp = Invoke-RestMethod -Uri $WebhookUrl -Method Post `
                                  -ContentType 'application/json; charset=utf-8' `
                                  -Body $bytes -TimeoutSec 20 -ErrorAction Stop
        $code = $null
        try { $code = $resp.errcode } catch {}
        if ($null -ne $code -and [int]$code -eq 0) { return $true }
        Write-Log ('  webhook replied: ' + ($resp | ConvertTo-Json -Compress)) 'WARN'
        return $false
    } catch {
        Write-Log ('  Invoke-RestMethod failed: ' + $_.Exception.Message) 'WARN'
    }

    # Fallback: HttpClient (different code path in the same .NET stack)
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $hc = [System.Net.Http.HttpClient]::new()
        $hc.Timeout = [TimeSpan]::FromSeconds(20)
        $content = [System.Net.Http.ByteArrayContent]::new($bytes)
        $content.Headers.ContentType =
            [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
        $r = $hc.PostAsync($WebhookUrl, $content).GetAwaiter().GetResult()
        $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ([int]$r.StatusCode -eq 200 -and $body -match '"errcode"\s*:\s*0') { return $true }
        Write-Log ('  HttpClient replied: ' + [int]$r.StatusCode + ' ' + $body) 'WARN'
    } catch {
        Write-Log ('  HttpClient failed: ' + $_.Exception.Message) 'WARN'
    }
    return $false
}

function Send-Wecom {
    param([string]$Text)

    if ($NoSend) {
        Write-Log ('[-NoSend] would send: ' + $Text) 'WARN'
        return $true
    }

    if (-not $WebhookConfigured) {
        # No key configured: report it instead of failing. Detection carries on.
        Write-Log ('[no key] not pushed: ' + $Text) 'WARN'
        return $false
    }

    $payload = @{ msgtype = 'text'; text = @{ content = $Text } } |
               ConvertTo-Json -Compress -Depth 5

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if (Invoke-WebhookOnce -Payload $payload) {
            Write-Log 'send: OK (errcode 0)'
            return $true
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 3 }
    }
    return $false
}

# ---- mouse ------------------------------------------------------------------
# VERBATIM equivalent of the click the original working seer.bat performed:
#
#   Add-Type -AssemblyName System.Windows.Forms
#   [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(X, Y)
#   Add-Type -Name 'U32' -Namespace 'Win' -MemberDefinition
#            '[DllImport("user32.dll")] public static extern void mouse_event(...);'
#   [Win.U32]::mouse_event(0x0002, 0, 0, 0, 0); Start-Sleep -Milliseconds 150
#   [Win.U32]::mouse_event(0x0004, 0, 0, 0, 0)
#
# Same API, same coordinate space (process stays DPI-unaware), same 150 ms
# between button down and up. Nothing else.
function Invoke-Click {
    param([int]$X, [int]$Y)
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('Win.U32' -as [type])) {
        Add-Type -Namespace 'Win' -Name 'U32' -MemberDefinition @'
[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, uint extra);
'@
    }
    [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($X, $Y)
    [Win.U32]::mouse_event(0x0002, 0, 0, 0, 0)
    Start-Sleep -Milliseconds 150
    [Win.U32]::mouse_event(0x0004, 0, 0, 0, 0)
}

# Click an XM button by NAME (UI Automation), falling back to fixed pixels.
#
# The button is located from the live control tree, so this keeps working when
# the window moves or the layout changes - which is exactly what broke the
# hard-coded (890,590). The fallback preserves the original behaviour if the
# control cannot be found.
function Invoke-ButtonClick {
    # Locate a button by name (UI Automation) and click it. With -Wait the click
    # happens as soon as the control is ready, plus -SettleSeconds. That is what
    # makes this far faster than the old fixed 60s sleeps.
    param(
        [ValidateSet('enter', 'login', 'start')][string]$Key,
        [int]$TimeoutSeconds = 180,
        [int]$FallbackX = 0,
        [int]$FallbackY = 0
    )
    if ($UseFixedCoords) {
        Write-Log ('  -UseFixedCoords: clicking fixed pixel (' + $FallbackX + ',' + $FallbackY + ')')
        Invoke-Click -X $FallbackX -Y $FallbackY
        return $true
    }

    $ui = Join-Path $Bin 'click_ui.ps1'
    if (-not (Test-Path -LiteralPath $ui)) {
        Write-Log ('  click_ui.ps1 missing at ' + $ui) 'ERROR'
        return $false
    }
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $ui -Key $Key -Wait `
                        -TimeoutSeconds $TimeoutSeconds -SettleSeconds $SettleSeconds 2>&1
    $rc = $LASTEXITCODE
    $txt = (($out | Out-String).Trim())
    if ($txt) { Write-Log ('  ui-click: ' + $txt) }
    if ($rc -ne 0) {
        Write-Log ('  ui-click failed for key=' + $Key + ' (exit ' + $rc + ')') 'ERROR'
        return $false
    }

    # click_ui.ps1 reports which label actually matched. For -Key enter it may
    # have matched 'enter_update' (the "new version" prompt) instead. Stash it so
    # the caller can tell the user that a new version is waiting.
    $script:LastClickedKey = $Key
    if ($txt -match 'found key=(\S+)') { $script:LastClickedKey = $Matches[1] }
    return $true
}

function Get-NewVersionNotifyText {
    # Message sent when XM showed the "a newer version exists" prompt and we
    # clicked through it.
    return $P_UPDATE_NOTIFY
}

# ---- locate the XM log box across ALL of XM's top-level windows ------------
#
# We must NOT rely on Process.MainWindowHandle. XM opens additional top-level
# windows as the flow progresses (clicking "enter offline mode" brings up a new
# screen), and MainWindowHandle then points at whichever window currently has
# focus while the log box lives in a different one. Observed in the 23:23 run:
# after the first click the log became unreadable while XM was still running
# perfectly. So enumerate every top-level window owned by XM.exe and look for
# the log box in each of them.
# UI Automation is required by every log-reading function below. This load was
# accidentally dropped when the mouse helper was rewritten, and the failure was
# SILENT: FromHandle() threw
#   "Unable to find type [System.Windows.Automation.AutomationElement]"
# every reader call swallowed it and returned null/-1, so detection reported
# "log not readable yet" forever even though XM was running perfectly.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

if (-not ('Win.XW' -as [type])) {
    # Note: -MemberDefinition wraps this in a class, so NO using directives are
    # allowed here; everything must be fully qualified.
    Add-Type -Namespace 'Win' -Name 'XW' -MemberDefinition @'
public delegate bool EnumProc(IntPtr h, IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")]
static extern bool EnumWindows(EnumProc cb, IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")]
static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);

public static IntPtr[] WindowsOfPids(int[] pids) {
    System.Collections.Generic.List<IntPtr> found = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        for (int i = 0; i < pids.Length; i++) {
            if ((int)pid == pids[i]) { found.Add(h); break; }
        }
        return true;
    }, IntPtr.Zero);
    return found.ToArray();
}

// Every top-level window on the desktop (used only as a last-resort fallback).
public static IntPtr[] AllTopLevel() {
    System.Collections.Generic.List<IntPtr> found = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
    return found.ToArray();
}

[System.Runtime.InteropServices.DllImport("user32.dll")]
static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr l);

// Every child window (recursively) of the given top-level windows.
public static IntPtr[] ChildWindowsOf(IntPtr[] tops) {
    System.Collections.Generic.List<IntPtr> found = new System.Collections.Generic.List<IntPtr>();
    for (int i = 0; i < tops.Length; i++) {
        EnumChildWindows(tops[i], delegate(IntPtr h, IntPtr l) { found.Add(h); return true; }, IntPtr.Zero);
    }
    return found.ToArray();
}
'@
}

function Get-XMWindows {
    # Every window owned by an XM.exe process: top-level windows AND their child
    # windows (recursively). The log box can live in a child window, which a
    # top-level-only scan would never see.
    $procs = @(Get-Process -Name 'XM' -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return @() }
    $pids = @($procs | ForEach-Object { [int]$_.Id })
    try {
        $tops = @([Win.XW]::WindowsOfPids($pids))
        if ($tops.Count -eq 0) { return @() }
        $kids = @([Win.XW]::ChildWindowsOf($tops))
        $all = New-Object System.Collections.ArrayList
        foreach ($h in $tops) { [void]$all.Add($h) }
        foreach ($h in $kids) { if (-not $all.Contains($h)) { [void]$all.Add($h) } }
        return @($all.ToArray())
    } catch { return @() }
}

function Get-LogLinesFromName {
    param([string]$Name)
    if (-not $Name) { return @() }
    return @($Name -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
}

function Test-LogBoxName {
    # Is this control's Name the XM log box?
    #
    # Do NOT pick "the longest text": several controls hold long text and the
    # longest one is NOT necessarily the log. Identify the log box by CONTENT.
    #
    # Real log (captured 23:56, 29 lines, see README):
    #   line 1  timestamp + game data loading
    #   line 5  timestamp + start executing [custom magic - FLash]
    #   last    timestamp + all selected tasks finished
    #
    # The rule is deliberately generous about line position and strict about
    # content, so a log that has rolled, been cleared, or is mid-run still
    # matches while unrelated long text never does.
    param([string]$Name)
    if (-not $Name) { return $false }
    $lines = Get-LogLinesFromName -Name $Name
    if ($lines.Count -lt 3) { return $false }
    if ($lines[0] -notmatch '^\[\d{1,2}:\d{2}:\d{2}\]') { return $false }

    # (a) the completion line is present -> this is the XM task log
    foreach ($l in $lines) {
        if (Test-DoneLine -Line $l) { return $true }
    }


    #     Covers mid-run logs where no completion line exists yet.
    foreach ($l in $lines) {
        if (Test-StartLine -Line $l) { return $true }
    }

    # (c) weaker fallback: any task list header or custom magic mention
    foreach ($l in $lines) {
        if ($l.Contains($P_CUSTOM)) { return $true }
        if ($l.Contains($P_START) -and $l.Contains('[')) { return $true }
    }

    return $false
}

function Get-SystemLogText {
    # Desktop-wide last resort. DO NOT enable this by default: building the UIA
    # tree of up to 400 unrelated windows can take tens of seconds, which
    # starves the 1-second polling loop and makes detection miss its window.
    # Observed: with this enabled, the detection phase produced no per-poll log
    # lines at all (each poll was taking far longer than the 1s sleep).
    # Only used with -ScanAllProcesses, for the case where the log box is owned
    # by a different process than XM.
    $hits = 0
    foreach ($h in @([Win.XW]::AllTopLevel())) {
        $t = Get-LogTextFromWindow -Hwnd $h
        if ($t) { return $t }
        $hits++
        if ($hits -gt 400) { break }
    }
    return $null
}

function Get-EditControlCount {
    # Diagnostics only: how many Edit-class controls does this window expose?
    param([IntPtr]$Hwnd)
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
        if ($null -eq $root) { return -1 }
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Edit')
        $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        return $edits.Count
    } catch { return -1 }
}

function Get-LogTextFromWindow {
    # Read the log box out of ONE top-level window.
    #
    # Do NOT walk every descendant first: once XM is fully running it owns ~24
    # top-level windows and a full TreeScope.Descendants + TrueCondition walk
    # over all of them is slow and throws mid-walk. Ask for the Edit-class
    # controls first (that is what the log box is), then fall back to a full scan.
    #
    # NOTE: the log box reports ClassName 'Edit' but its ControlType is 'Pane',
    # so match on ClassName, never on ControlType.
    #
    # A real run lasts 30-50 minutes and the control text gets very long. The
    # property reads below are therefore individually guarded: one failing
    # element must not abort the search for the rest.
    param([IntPtr]$Hwnd)
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    } catch { return $null }
    if ($null -eq $root) { return $null }

    # 1) Edit-class controls, accepted only if they look like the log box.
    try {
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ClassNameProperty, 'Edit')
        $edits = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
        for ($i = 0; $i -lt $edits.Count; $i++) {
            try {
                $n = [string]$edits.Item($i).Current.Name
                if (Test-LogBoxName -Name $n) { return $n }
            } catch { }
        }
    } catch { }

    # 2) Fallback: scan every child of this window, still guarded per element.
    try {
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                             [System.Windows.Automation.Condition]::TrueCondition)
        for ($i = 0; $i -lt $all.Count; $i++) {
            try {
                $n = [string]$all.Item($i).Current.Name
                if (Test-LogBoxName -Name $n) { return $n }
            } catch { }
        }
    } catch { }

    return $null
}

function Get-XMLogText {
    # Prefer the process main window (that is where the log box lives), then walk
    # the remaining top-level windows. Stop as soon as one yields the log box.
    $mainHwnd = [IntPtr]::Zero
    try {
        $pr = Get-Process -Name 'XM' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pr -and $pr.MainWindowHandle -ne 0) { $mainHwnd = $pr.MainWindowHandle }
    } catch {}

    if ($mainHwnd -ne [IntPtr]::Zero) {
        $t = Get-LogTextFromWindow -Hwnd $mainHwnd
        if ($t) { return $t }
    }

    foreach ($h in (Get-XMWindows)) {
        if ($h -eq $mainHwnd) { continue }
        $t = Get-LogTextFromWindow -Hwnd $h
        if ($t) { return $t }
    }

    # Nothing under XM's own windows. Only if explicitly asked, fall back to a
    # desktop-wide content search (slow - see Get-SystemLogText).
    if ($ScanAllProcesses) {
        $t = Get-SystemLogText
        if ($t) { return $t }
    }

    return $null
}

function Test-StartLine {
    # Matches the line that marks this run as started:

    #



    # daily list.
    param([string]$Line)
    if (-not $Line) { return $false }
    if (-not $Line.Contains($P_START)) { return $false }


    if (-not $Line.Contains($M_START_OPEN)) { return $false }

    # the exact target
    if ($Line.Contains($P_DAILY)) { return $true }

    # a custom-magic list header is a different list -> reject
    if ($Line.Contains($M_MAGIC_HEADER)) { return $false }


    return $true
}

function Get-StartNotifyText {
    # Notification text for the start line: keep the timestamp, drop the list
    # name. So

    # becomes

    # Falls back to the whole line if the shape is unexpected, so a notification
    # is never lost.
    param([string]$Line)
    if (-not $Line) { return $Line }
    # Accept an optional fractional part; real XM lines carry [hh:mm:ss] only.
    $m = [regex]::Match($Line, '^\[\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\]')
    if ($m.Success) { return ($m.Value + ':' + $P_START) }
    return $Line
}

function Test-DoneLine {
    param([string]$Line)
    return $Line.Contains($P_DONE)
}

# Test hook: a provider script can replace the log reader entirely.
if ($LogProviderPath -and (Test-Path -LiteralPath $LogProviderPath)) {
    . $LogProviderPath
    Write-Host ('[INFO] using test log provider: ' + $LogProviderPath)
}

function Get-LogLines {
    $txt = Get-XMLogText
    if ($null -eq $txt) { return $null }
    return @($txt -split "`r?`n" | Where-Object { $_ -ne '' })
}

function Get-MatchingLines {
    # All log lines matching the marker we are waiting for.
    param([ValidateSet('start', 'done')][string]$Kind, [string[]]$Lines)
    $hits = @()
    foreach ($l in $Lines) {
        if ($Kind -eq 'start') {
            if (Test-StartLine -Line $l) { $hits += $l }
        } else {
            if (Test-DoneLine -Line $l) { $hits += $l }
        }
    }
    return $hits
}

function New-SeenSet {
    # Snapshot of matching lines that already existed BEFORE our click.
    # Detection = a matching line that is not in this set.
    #
    # Why a set of line texts and not a count: the XM log box is a rolling
    # window, so adding a new line can push an old one out and the COUNT stays
    # the same. Line text (it carries a HH:mm:ss timestamp) is unique per run.
    param([ValidateSet('start', 'done')][string]$Kind)
    $lines = Get-LogLines
    $seen = @{}
    if ($null -eq $lines) {
        Write-Log ("baseline for '$Kind': log not readable yet")
        return $seen
    }
    $hits = Get-MatchingLines -Kind $Kind -Lines $lines
    foreach ($h in $hits) { $seen[$h] = $true }
    Write-Log ("baseline for '$Kind': total lines=" + $lines.Count + ", existing matches=" + $hits.Count)
    if ($lines.Count -gt 0) { Write-Log ("  newest log line: " + $lines[-1]) }
    return $seen
}

function Show-Desktop {
    # Minimise XM and bring the desktop forward.
    #
    # Called on DETECTING THE START LINE (not right after the click): the log
    # box only becomes readable once the game has connected, and the reading is
    # done through UI Automation, which keeps working while minimised.
    Write-Log '--- returning to the desktop (minimising XM) ---'
    if (-not ('Win.DT' -as [type])) {
        Add-Type -Namespace 'Win' -Name 'DT' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr FindWindowW(string cls, string win);
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
'@
    }
    foreach ($h in (Get-XMWindows)) {
        [void][Win.DT]::ShowWindow($h, 6)          # SW_MINIMIZE
    }
    try {
        $prog = [Win.DT]::FindWindowW('Progman', $null)
        if ($prog -ne [IntPtr]::Zero) {
            [void][Win.DT]::ShowWindow($prog, 6)   # SW_MINIMIZE
            Start-Sleep -Milliseconds 150
            [void][Win.DT]::ShowWindow($prog, 9)   # SW_RESTORE
        }
    } catch {}
    Start-Sleep -Milliseconds 400
    Write-Log 'desktop shown; XM minimised (log is still readable)'
}

function Wait-DoneLine {
    # Wait for the completion line by checking ONLY the newest log line, every
    # $PollSeconds (default 5 minutes).
    #
    # Why this shape: a run can last hours. Snapshotting/set-comparing the whole
    # log on every 1s poll costs memory and CPU for no benefit, because the
    # completion line is always the LAST line the log shows.
    param(
        [int]$TimeoutSeconds,
        [int]$PollSeconds = 300
    )
    $t0 = Get-Date
    $deadline = $t0.AddSeconds($TimeoutSeconds)
    $warned = $false
    $lastSeen = ''

    while ($true) {
        $lines = Get-LogLines
        if ($null -ne $lines -and $lines.Count -gt 0) {
            $warned = $false
            $newest = $lines[-1]
            if ($newest -ne $lastSeen) {
                $lastSeen = $newest
                $el = [int](((Get-Date) - $t0).TotalSeconds)
                Write-Log ("  t+${el}s newest: " + $newest)
            }
            if (Test-DoneLine -Line $newest) { return $newest }
        } elseif (-not $warned) {
            Write-Log 'log not readable while waiting for completion' 'WARN'
            $warned = $true
        }

        if ((Get-Date) -gt $deadline) { return $null }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Wait-NewMarker {
    # Wait for a matching line that is NOT in $Seen (i.e. produced by this run).
    param(
        [ValidateSet('start', 'done')][string]$Kind,
        [int]$TimeoutSeconds,
        [hashtable]$Seen
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $t0 = Get-Date
    $poll = 1
    $warned = $false
    $lastLogged = ''

    while ($true) {
        $lines = Get-LogLines
        if ($null -ne $lines) {
            $warned = $false
            $hits = Get-MatchingLines -Kind $Kind -Lines $lines
            $fresh = @($hits | Where-Object { -not $Seen.ContainsKey($_) })
            if ($fresh.Count -gt 0) {
                return $fresh[-1]
            }
            if ($AllowExisting -and $hits.Count -gt 0) {
                Write-Log ("ALLOW-EXISTING hit: " + $hits[-1])
                return $hits[-1]
            }
            $key = '' + $lines.Count + '|' + $lines[-1]
            if ($key -ne $lastLogged) {
                $lastLogged = $key
                Write-Log ("  log now has " + $lines.Count + " lines, newest: " + $lines[-1])
            }
        } elseif (-not $warned) {
            # Say exactly what is missing: no XM process, no windows, or windows
            # that exist but expose no log box. Those are different problems.
            $wins = @(Get-XMWindows)
            $main = 0
            try {
                $pr = Get-Process -Name 'XM' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($pr) { $main = $pr.MainWindowHandle }
            } catch {}
            $editCount = -1
            if ($main -ne 0) { $editCount = Get-EditControlCount -Hwnd ([IntPtr]$main) }
            Write-Log ('log not readable yet: XM processes=' +
                       @(Get-Process -Name 'XM' -ErrorAction SilentlyContinue).Count +
                       ', top-level windows=' + $wins.Count +
                       ', MainWindowHandle=0x' + ('{0:X}' -f [int64]$main) +
                       ', Edit-controls in main window=' + $editCount) 'WARN'
            Write-Log ('  run probe_xm_windows.ps1 to dump every long text control') 'WARN'
            $warned = $true
        }

        if ((Get-Date) -gt $deadline) { return $null }
        $now = Get-Date
        if ($Kind -eq 'start') {
            $elapsed = [int](((Get-Date) - $t0).TotalSeconds)
            Write-Log ("  poll t+${elapsed}s: " + $(if ($null -eq $txt) { 'no log box yet' } else { "chars=" + $txt.Length }))
        }
        Start-Sleep -Seconds $poll
    }
}

# =============================================================================
# A WeCom key is OPTIONAL. With no key the script still does the whole job -
# launching XM, clicking through the screens, watching the log and reporting
# every milestone on the console - it just cannot push to WeCom. That makes the
# script usable straight after cloning, before any key has been configured.
if (-not $WebhookUrl -or $WebhookUrl -match 'YOUR-KEY-HERE') {
    $WebhookConfigured = $false
} else {
    $WebhookConfigured = $true
}

Write-Log '================ seer_run start ================'
if ($WebhookConfigured) {
    Write-Log ("webhook : " + $WebhookDisplay + "   (from " + $WebhookSource + ")")
} else {
    Write-Log 'webhook : NOT CONFIGURED - milestones are only printed to the console,' 'WARN'
    Write-Log '          put your robot key in wecom_key.txt to enable WeCom push' 'WARN'
}
Write-Log ("xm path : " + $XmExe + "   (from " + $XmSource + ")")
Write-Log ("start marker : " + $M_START_DAILY)
Write-Log ("done marker  : " + $P_DONE)
Write-Log ("wait budgets: enter=${EnterTimeoutSeconds}s login=${LoginTimeoutSeconds}s start=${StartTimeoutSeconds}s settle=${SettleSeconds}s")
Write-Log ("detect=${DetectWindowSeconds}s done=${DoneTimeoutSeconds}s")
if ($UseFixedCoords) {
    Write-Log ("mode: FIXED PIXELS enter=($EnterX,$EnterY) login=($LoginX,$LoginY) start=($StartX,$StartY)")
} else {
    Write-Log 'mode: click buttons located through UI Automation (name-based)'
}

# =============================================================================
#  STEP 1 - launch XM, then click each control as soon as it is ready.
#
#  1) "enter offline mode" appears -> wait -SettleSeconds -> click
#     (this opens the next screen)
#  2) "login" appears              -> wait -SettleSeconds -> click
#  3) "start" becomes ENABLED      -> wait -SettleSeconds -> click
#     (XM enables "start" only after login succeeds)
#
#  One click each. No retry loop, no blind long sleeps.
# =============================================================================
$seenStart = $null

if (-not $SkipLaunch) {
    Write-Log ('launching ' + $XmExe)
    if (-not (Test-Path -LiteralPath $XmExe)) {
        Write-Log ('XM.exe not found: ' + $XmExe) 'ERROR'
        Write-Log ("exit " + 9)
        Write-ExitSummary -Code 9
        exit 9
    }
    Start-Process -FilePath $XmExe | Out-Null

    Write-Log '--- step 1/3: waiting for the "enter offline mode" button ---'
    if (-not (Invoke-ButtonClick -Key enter -TimeoutSeconds $EnterTimeoutSeconds `
                                 -FallbackX $EnterX -FallbackY $EnterY)) {
        Write-Log '"enter offline mode" never became clickable' 'ERROR'
        Write-Log ("exit " + 4)
        Write-ExitSummary -Code 4
        exit 4
    }

    # Give the next screen a moment to appear before looking for the login
    # button; otherwise the wait starts while the old screen is still shown.
    if ($SettleSeconds -gt 0) {
        Write-Log ('  waiting ' + $SettleSeconds + 's for the next screen...')
        Start-Sleep -Seconds $SettleSeconds
    }

    # If the update prompt was the one we clicked, tell the user.
    if ($script:LastClickedKey -eq 'enter_update') {
        $uvMsg = Get-NewVersionNotifyText
        Write-Log ('new-version prompt detected; notifying: ' + $uvMsg) 'WARN'
        if (Send-Wecom -Text $uvMsg) { Write-Log 'new-version notification sent.' }
        else { Write-Log 'new-version notification FAILED.' 'ERROR' }
    }

    Write-Log '--- step 2/3: waiting for the "login" button ---'
    if (-not (Invoke-ButtonClick -Key login -TimeoutSeconds $LoginTimeoutSeconds `
                                 -FallbackX $LoginX -FallbackY $LoginY)) {
        Write-Log '"login" never became clickable' 'ERROR'
        Write-Log ("exit " + 5)
        Write-ExitSummary -Code 5
        exit 5
    }

    # Snapshot the log BEFORE clicking start: a magic can finish in seconds, so
    # the start line this run produces must be recognised as new, and polling
    # must begin with no sleep after the click.
    $seenStart = New-SeenSet -Kind 'start'

    Write-Log '--- step 3/3: waiting for the "start" button to be ENABLED ---'
    if (-not (Invoke-ButtonClick -Key start -TimeoutSeconds $StartTimeoutSeconds `
                                 -FallbackX $StartX -FallbackY $StartY)) {
        Write-Log '"start" never became enabled' 'ERROR'
        Write-Log ("exit " + 6)
        Write-ExitSummary -Code 6
        exit 6
    }

} else {
    Write-Log 'SkipLaunch: no XM start / no clicks'
    $seenStart = New-SeenSet -Kind 'start'
}

Write-Log ('--- waiting for the start line, up to ' + $DetectWindowSeconds +
          's (the log box appears only after the game connects) ---')
$startLine = Wait-NewMarker -Kind 'start' -TimeoutSeconds $DetectWindowSeconds -Seen $seenStart

if (-not $startLine) {
    Write-Log ('start line not detected within ' + $DetectWindowSeconds + 's') 'ERROR'
    Write-Log 'notifying failure...'
    if (Send-Wecom -Text $P_FAILMSG) { Write-Log 'failure notification sent.' }
    else { Write-Log 'failure notification FAILED.' 'ERROR' }
    Write-Log '================ seer_run end (fail) ================'
    Write-Log ("exit " + 2)
    Write-ExitSummary -Code 2
    exit 2
}

Write-Log ('start detected: ' + $startLine)
$startMsg = Get-StartNotifyText -Line $startLine
Write-Log ('notifying: ' + $startMsg)
if (Send-Wecom -Text $startMsg) { Write-Log 'start notification sent.' }
else { Write-Log 'start notification FAILED.' 'ERROR' }

# ---- on detecting the start line: hand the desktop back to the user ---------
# This is the point where XM is fully up and the tasks are running, so it is
# safe to minimise it. Detection continues to work while minimised.
if ($ReturnToDesktop) {
    Show-Desktop
}

# ---- wait for the completion line -------------------------------------------
# Checks ONLY the newest log line, once every $DonePollSeconds (default 5min),
# instead of snapshotting the whole log every second.
Write-Log ('--- waiting for the completion line, up to ' + $DoneTimeoutSeconds +
           's, checking every ' + $DonePollSeconds + 's ---')
$doneLine = Wait-DoneLine -TimeoutSeconds $DoneTimeoutSeconds -PollSeconds $DonePollSeconds

if (-not $doneLine) {
    Write-Log 'completion line not detected (timeout) -> notifying timeout' 'WARN'
    if (Send-Wecom -Text $P_TIMEMSG) { Write-Log 'timeout notification sent.' }
    else { Write-Log 'timeout notification FAILED.' 'ERROR' }
    Write-Log '================ seer_run end (timeout) ================'
    Write-Log ("exit " + 3)
    Write-ExitSummary -Code 3
    exit 3
}

Write-Log ('completion detected: ' + $doneLine)
Write-Log 'notifying completion line...'
if (Send-Wecom -Text $doneLine) { Write-Log 'completion notification sent.' }
else { Write-Log 'completion notification FAILED.' 'ERROR' }

Write-Log '================ seer_run end (ok) ================'
Write-Log ("exit " + 0)
Write-ExitSummary -Code 0
exit 0
