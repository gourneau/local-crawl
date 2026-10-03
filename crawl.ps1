<#
.SYNOPSIS
  Start, stop, and check a local fastCRW crawl server on Windows.

.DESCRIPTION
  Runs two background processes:
    - headless Chrome (or Edge) with a private profile, used to render JS-heavy pages
    - crw-server.exe, the Firecrawl-compatible REST API

  Both bind to 127.0.0.1 only, so nothing is reachable from other machines.

.EXAMPLE
  .\crawl.ps1 start
  .\crawl.ps1 start -Headed      # show the browser window, for debugging
  .\crawl.ps1 status
  .\crawl.ps1 scrape https://example.com
  .\crawl.ps1 stop
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('start', 'stop', 'restart', 'status', 'logs', 'scrape')]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [string]$Url,

    # Run Chrome with a visible window so you can watch pages render.
    [switch]$Headed
)

$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------
$ApiPort = 3002   # crw API: http://127.0.0.1:3002 (3000 is left free for dev servers)
$CdpPort = 9223   # headless Chrome DevTools port, used only by crw

$Root       = $PSScriptRoot
$CrwExe     = Join-Path $Root 'bin\crw-server.exe'
$RunDir     = Join-Path $Root 'run'
$LogDir     = Join-Path $Root 'logs'
$ProfileDir = Join-Path $Root '.chrome-profile'
$ApiUrl     = "http://127.0.0.1:$ApiPort"
# 'headed' or 'headless'; also read by the tray app for its Options menu.
$BrowserModeFile = Join-Path $RunDir 'browser.mode'

$BrowserCandidates = @(
    $env:CRW_BROWSER,
    # Chrome for Testing: a pinned build that never auto-updates. Used when present.
    (Join-Path $Root 'browser\chrome-win64\chrome.exe'),
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
)

# --- Helpers ------------------------------------------------------------------
function Get-PidFile([string]$Name) { Join-Path $RunDir "$Name.pid" }

# Returns the live process recorded in run\<Name>.pid, or $null. The process name
# is checked so a recycled PID never gets mistaken for (or killed as) ours.
function Get-Tracked([string]$Name, [string[]]$ExpectedNames) {
    $file = Get-PidFile $Name
    if (-not (Test-Path $file)) { return $null }
    $procId = [int](Get-Content $file -Raw)
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc -and $ExpectedNames -contains $proc.ProcessName) { return $proc }
    Remove-Item $file -Force
    return $null
}

function Test-Url([string]$Url) {
    try {
        $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
        return $true
    } catch {
        return $false
    }
}

function Wait-Url([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Url $Url) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Assert-PortFree([int]$Port, [string]$What) {
    # Only listeners on loopback or all interfaces clash with our 127.0.0.1 bind. Others are
    # fine, e.g. `tailscale serve` forwarding the same port on the Tailscale address.
    $owner = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in '127.0.0.1', '0.0.0.0', '::' } |
        Select-Object -First 1
    if ($owner) {
        $procName = (Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        throw "Port $Port (needed for $What) is already used by $procName (PID $($owner.OwningProcess)). Change the port at the top of crawl.ps1."
    }
}

function Stop-Tracked([string]$Name, [string[]]$ExpectedNames) {
    $proc = Get-Tracked $Name $ExpectedNames
    if ($proc) {
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
        Write-Host "  stopped $Name (PID $($proc.Id))"
    }
    Remove-Item (Get-PidFile $Name) -Force -ErrorAction SilentlyContinue
}

# The crawler's browser: the process serving DevTools on $CdpPort, but only if it uses
# our private profile, so your everyday Chrome is never touched. This is more reliable
# than the PID Start-Process returns, because chrome.exe can hand off to a new process
# and exit (for example right after Chrome updates itself).
function Get-Browser {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $CdpPort -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $conn) { return $null }
    $info = Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)"
    if (-not $info -or -not $info.CommandLine -or -not $info.CommandLine.Contains($ProfileDir)) { return $null }
    return Get-Process -Id $info.ProcessId -ErrorAction SilentlyContinue
}

function Stop-Browser {
    $proc = Get-Browser
    if ($proc) {
        # /T takes down Chrome's renderer/GPU child processes too.
        & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null
        Write-Host "  stopped browser (PID $($proc.Id))"
    }
    Remove-Item (Get-PidFile 'browser') -Force -ErrorAction SilentlyContinue
    Remove-Item $BrowserModeFile -Force -ErrorAction SilentlyContinue
}

# Chrome is stopped with taskkill, so it records the exit as a crash and offers
# "Restore pages?" on the next start. Mark the last exit as clean first.
function Clear-ChromeCrashFlag {
    foreach ($file in (Join-Path $ProfileDir 'Default\Preferences'), (Join-Path $ProfileDir 'Local State')) {
        if (-not (Test-Path $file)) { continue }
        $text = [IO.File]::ReadAllText($file)
        $fixed = $text -replace '"exit_type"\s*:\s*"[^"]*"', '"exit_type":"Normal"' `
                       -replace '"exited_cleanly"\s*:\s*false', '"exited_cleanly":true'
        if ($fixed -ne $text) { [IO.File]::WriteAllText($file, $fixed) }
    }
}

# The crawler browser's own User-Agent, minus the "Headless" marker, or $null if it isn't up.
function Get-BrowserUserAgent {
    try {
        $info = Invoke-RestMethod "http://127.0.0.1:$CdpPort/json/version" -TimeoutSec 3
        return ($info.'User-Agent' -replace 'HeadlessChrome', 'Chrome')
    } catch {
        return $null
    }
}

# --- Commands -----------------------------------------------------------------
function Start-Browser {
    if (Get-Browser) {
        $current = Get-Content $BrowserModeFile -Raw -ErrorAction SilentlyContinue
        $wanted = if ($Headed) { 'headed' } else { 'headless' }
        if ($current -and $current -ne $wanted) {
            Write-Warning "Browser is already running $current. Use 'restart' to switch it to $wanted."
        } else {
            Write-Host "  browser already running"
        }
        return
    }
    $exe = $BrowserCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $exe) {
        Write-Warning "No Chrome or Edge found. JS-heavy pages will not render. Set CRW_BROWSER to a chrome.exe path to fix."
        return
    }
    Assert-PortFree $CdpPort 'the crawler browser'

    Clear-ChromeCrashFlag

    $browserArgs = @(
        "--remote-debugging-port=$CdpPort",
        '--remote-debugging-address=127.0.0.1',
        "--user-data-dir=`"$ProfileDir`"",
        '--no-first-run',
        '--no-default-browser-check',
        '--hide-crash-restore-bubble',
        '--disable-component-update',
        '--disable-extensions',
        '--disable-sync',
        '--disable-background-networking',
        # No navigator.webdriver flag, also in workers, which crw's injected script can't reach.
        '--disable-blink-features=AutomationControlled',
        'about:blank'
    )
    if ($Headed) {
        $mode = 'headed'
        $windowStyle = 'Normal'
    } else {
        $mode = 'headless'
        $windowStyle = 'Hidden'
        # The GPU stays on: software rendering is a well-known headless fingerprint.
        $browserArgs = @('--headless=new') + $browserArgs
    }
    $null = Start-Process -FilePath $exe -ArgumentList $browserArgs -WindowStyle $windowStyle `
        -RedirectStandardError (Join-Path $LogDir 'browser.log') `
        -RedirectStandardOutput (Join-Path $LogDir 'browser.out.log')
    Set-Content -Path $BrowserModeFile -Value $mode -NoNewline

    if (Wait-Url "http://127.0.0.1:$CdpPort/json/version" 15) {
        $browser = Get-Browser
        if ($browser) { Set-Content -Path (Get-PidFile 'browser') -Value $browser.Id -NoNewline }
        Write-Host "  browser up   ($(Split-Path $exe -Leaf), $mode, DevTools on 127.0.0.1:$CdpPort)"
    } else {
        Write-Warning "Browser did not open port $CdpPort. See logs\browser.log. crw will still serve plain HTML pages."
    }
}

function Start-Crw {
    if (Get-Tracked 'crw-server' @('crw-server')) {
        Write-Host "  crw-server already running"
        return
    }
    if (-not (Test-Path $CrwExe)) { throw "Missing $CrwExe. Run .\setup.ps1 first to download fastCRW." }
    Assert-PortFree $ApiPort 'crw-server'

    # Environment variables override config.local.toml, so the ports live in one place (this file).
    $env:CRW_SERVER__HOST = '127.0.0.1'
    $env:CRW_SERVER__PORT = "$ApiPort"
    $env:CRW_RENDERER__CHROME__WS_URL = "ws://127.0.0.1:$CdpPort/"

    # crw presents a fixed "Chrome on Mac" User-Agent by default. Present the browser's
    # real one instead, so the header matches what page scripts see about the machine.
    $realUa = Get-BrowserUserAgent
    if ($realUa) { $env:CRW_CRAWLER__USER_AGENT = $realUa }
    if (-not $env:RUST_LOG) { $env:RUST_LOG = 'info' }

    $proc = Start-Process -FilePath $CrwExe -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir 'crw-server.log') `
        -RedirectStandardError (Join-Path $LogDir 'crw-server.err.log')
    Set-Content -Path (Get-PidFile 'crw-server') -Value $proc.Id -NoNewline

    if (Wait-Url "$ApiUrl/health" 30) {
        Write-Host "  crw-server up ($ApiUrl)"
    } else {
        Write-Host ""
        Get-Content (Join-Path $LogDir 'crw-server.log'), (Join-Path $LogDir 'crw-server.err.log') -Tail 20 -ErrorAction SilentlyContinue
        throw "crw-server did not become healthy within 30s. Full logs are in $LogDir."
    }
}

function Invoke-Start {
    New-Item -ItemType Directory -Force -Path $RunDir, $LogDir | Out-Null
    Write-Host "Starting local crawler..."
    try {
        Start-Browser
        Start-Crw
    } catch {
        # Don't leave a half-started setup behind (e.g. a browser with no server).
        Stop-Tracked 'crw-server' @('crw-server')
        Stop-Browser
        throw
    }
    Write-Host ""
    Write-Host "Ready. API:  $ApiUrl  (Firecrawl-compatible: /v1/scrape, /v1/crawl, /v1/map)"
    Write-Host "Try:         .\crawl.ps1 scrape https://example.com"
    Write-Host "Stop with:   .\crawl.ps1 stop   (or double-click stop.cmd)"
}

function Invoke-Stop {
    Write-Host "Stopping local crawler..."
    Stop-Tracked 'crw-server' @('crw-server')
    Stop-Browser
    Write-Host "Stopped."
}

function Invoke-Status {
    $crw = Get-Tracked 'crw-server' @('crw-server')
    $browser = Get-Browser

    if ($crw) {
        $mb = [math]::Round($crw.WorkingSet64 / 1MB, 1)
        $health = if (Test-Url "$ApiUrl/health") { 'healthy' } else { 'NOT responding' }
        Write-Host "crw-server : running, PID $($crw.Id), $mb MB, $health at $ApiUrl"
    } else {
        Write-Host "crw-server : stopped"
    }

    if ($browser) {
        $cdp = if (Test-Url "http://127.0.0.1:$CdpPort/json/version") { 'DevTools ok' } else { 'DevTools NOT responding' }
        $mode = Get-Content $BrowserModeFile -Raw -ErrorAction SilentlyContinue
        Write-Host "browser    : running, PID $($browser.Id), $mode, $cdp on port $CdpPort"
    } else {
        Write-Host "browser    : stopped"
    }
}

function Invoke-Scrape {
    if (-not $Url) { throw "Usage: .\crawl.ps1 scrape <url>" }
    $body = @{ url = $Url } | ConvertTo-Json -Compress
    $resp = Invoke-WebRequest -Uri "$ApiUrl/v1/scrape" -Method Post -ContentType 'application/json' `
        -Body $body -UseBasicParsing -TimeoutSec 180
    # The API sends UTF-8 without a charset header; Windows PowerShell 5.1 would decode it as Latin-1.
    $result = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
    if (-not $result.success) { throw "Scrape failed: $($result.error)" }
    $result.data.markdown
}

$LastErrorFile = Join-Path $RunDir 'last-error.txt'
Remove-Item $LastErrorFile -Force -ErrorAction SilentlyContinue

try {
    switch ($Command) {
        'start'   { Invoke-Start }
        'stop'    { Invoke-Stop }
        'restart' { Invoke-Stop; Invoke-Start }
        'status'  { Invoke-Status }
        'logs'    { Get-Content (Join-Path $LogDir 'crw-server.log') -Tail 40 -Wait }
        'scrape'  { Invoke-Scrape }
    }
} catch {
    # Saved so the tray app can show why a start or stop failed.
    New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    Set-Content -Path $LastErrorFile -Value $_.Exception.Message
    throw
}
