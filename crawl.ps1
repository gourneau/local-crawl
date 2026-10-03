<#
.SYNOPSIS
  Start, stop, and check a local fastCRW crawl server on Windows.

.DESCRIPTION
  Runs two background processes:
    - Chrome (or Edge) with a private profile, used to render JS-heavy pages
    - crw-server.exe, the Firecrawl-compatible REST API

  Both bind to 127.0.0.1 only, so nothing is reachable from other machines.

.EXAMPLE
  .\crawl.ps1 start
  .\crawl.ps1 start -Browser visible   # watch pages render, for debugging
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

    # hidden:   a real browser window parked off-screen. Sites that detect headless
    #           Chrome see a normal desktop browser. The default.
    # visible:  an on-screen window, to watch pages render while debugging.
    # headless: no window at all. Lightest, but some sites block it.
    [ValidateSet('hidden', 'visible', 'headless')]
    [string]$Browser = 'hidden',

    # Same as -Browser visible (kept for older scripts).
    [switch]$Headed,

    # local:  crw-server.exe + your Chrome + the DevTools filter (the default).
    # docker: fastCRW's Docker stack: Chrome-impersonating HTTP, Camoufox and SearXNG
    #         search, rendering JS pages with the same Chrome and filter.
    #         Needs Docker Desktop and a one-time `.\setup.ps1 -Docker`.
    # Defaults to whichever engine is running (for restart), else local.
    [ValidateSet('local', 'docker')]
    [string]$Engine
)
if ($Headed) { $Browser = 'visible' }

$ErrorActionPreference = 'Stop'

# --- Settings -----------------------------------------------------------------
$ApiPort    = 3002   # crw API: http://127.0.0.1:3002 (3000 is left free for dev servers)
$CdpPort    = 9223   # DevTools port crw connects to (the filter, or Chrome if the filter is missing)
$ChromePort = 9224   # Chrome's own DevTools port, behind the filter

# DevTools commands from crw that the filter answers itself instead of passing to Chrome
# (comma-separated). Runtime.enable is a well-known automation giveaway; Fetch.enable
# makes Chrome pause every request for crw to approve. crw works fine without either, and
# pages then load like a normal visit. Override with $env:CRAWL_FILTER_DROP to experiment.
$FilterDrop = 'Runtime.enable,Fetch.enable'
if ($null -ne $env:CRAWL_FILTER_DROP) { $FilterDrop = $env:CRAWL_FILTER_DROP }

$Root       = $PSScriptRoot
$CrwExe     = Join-Path $Root 'bin\crw-server.exe'
$FilterExe  = Join-Path $Root 'bin\cdp-filter.exe'
$RunDir     = Join-Path $Root 'run'
$LogDir     = Join-Path $Root 'logs'
$ProfileDir = Join-Path $Root '.chrome-profile'
$ApiUrl     = "http://127.0.0.1:$ApiPort"
# The running browser's mode ('hidden', 'visible' or 'headless'); also read by the tray app.
$BrowserModeFile = Join-Path $RunDir 'browser.mode'
# The running engine ('local' or 'docker'); also read by the tray app.
$EngineFile  = Join-Path $RunDir 'engine'
$DockerDir   = Join-Path $Root 'docker'
$ComposeFile = Join-Path $DockerDir 'compose.yml'
$DockerImage = 'local-crawl/crw:0.37.2-stealth'

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

# The crawler's browser: the process serving DevTools on $ChromePort, but only if it uses
# our private profile, so your everyday Chrome is never touched. This is more reliable
# than the PID Start-Process returns, because chrome.exe can hand off to a new process
# and exit (for example right after Chrome updates itself).
function Get-Browser {
    $conn = Get-NetTCPConnection -State Listen -LocalPort $ChromePort -ErrorAction SilentlyContinue |
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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CrawlWindow {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr processId);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool on);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    // Give focus back to a window. Windows only lets the foreground thread do that, so
    // briefly share input state with it (the standard workaround).
    public static void Activate(IntPtr hWnd) {
        uint foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
        uint me = GetCurrentThreadId();
        bool attached = foregroundThread != me && AttachThreadInput(me, foregroundThread, true);
        BringWindowToTop(hWnd);
        SetForegroundWindow(hWnd);
        if (attached) AttachThreadInput(me, foregroundThread, false);
    }

    // Keep the window, but take it out of the taskbar and Alt+Tab and send it to the back
    // without activating it, so it never takes keyboard focus from what you're doing.
    public static void Tuck(IntPtr hWnd) {
        const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000, SW_HIDE = 0;
        const uint SWP_NOSIZE = 0x1, SWP_NOMOVE = 0x2, SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
        ShowWindow(hWnd, SW_HIDE);
        SetWindowLong(hWnd, GWL_EXSTYLE, (GetWindowLong(hWnd, GWL_EXSTYLE) | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW);
        SetWindowPos(hWnd, new IntPtr(1), 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }
}
'@

# Tuck the off-screen browser window away and hand focus back to whatever had it before.
function Hide-BrowserWindow([System.Diagnostics.Process]$Proc, [IntPtr]$PreviousForeground) {
    $deadline = (Get-Date).AddSeconds(10)
    while ($Proc.MainWindowHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $Proc.Refresh()
    }
    if ($Proc.MainWindowHandle -eq [IntPtr]::Zero) { return }
    [CrawlWindow]::Tuck($Proc.MainWindowHandle)
    if ($PreviousForeground -ne [IntPtr]::Zero -and $PreviousForeground -ne $Proc.MainWindowHandle) {
        [CrawlWindow]::Activate($PreviousForeground)
    }
}

# The crawler browser's own User-Agent, minus the "Headless" marker, or $null if it isn't up.
function Get-BrowserUserAgent {
    try {
        $info = Invoke-RestMethod "http://127.0.0.1:$ChromePort/json/version" -TimeoutSec 3
        return ($info.'User-Agent' -replace 'HeadlessChrome', 'Chrome')
    } catch {
        return $null
    }
}

# --- Commands -----------------------------------------------------------------
function Start-Browser {
    if (Get-Browser) {
        $current = Get-Content $BrowserModeFile -Raw -ErrorAction SilentlyContinue
        if ($current -and $current -ne $Browser) {
            Write-Warning "Browser is already running $current. Use 'restart' to switch it to $Browser."
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
    Assert-PortFree $ChromePort 'the crawler browser'

    Clear-ChromeCrashFlag

    $browserArgs = @(
        "--remote-debugging-port=$ChromePort",
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
    $windowStyle = 'Normal'
    switch ($Browser) {
        'headless' {
            # The GPU stays on: software rendering is a well-known headless fingerprint.
            # Headless Chrome calls itself "HeadlessChrome"; give it the normal name instead.
            $major = (Get-Item $exe).VersionInfo.ProductMajorPart
            $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$major.0.0.0 Safari/537.36"
            if ($exe -like '*msedge.exe') { $ua += " Edg/$major.0.0.0" }
            $browserArgs = @('--headless=new', "--user-agent=`"$ua`"") + $browserArgs
            $windowStyle = 'Hidden'
        }
        'hidden' {
            # A real window parked off-screen, kept rendering at full speed even though
            # nothing can see it (Chrome otherwise throttles windows it thinks are covered).
            # Size it to fit the real screen: a window bigger than the screen is a giveaway.
            Add-Type -AssemblyName System.Windows.Forms
            $work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $width = [Math]::Min(1600, $work.Width - 40)
            $height = [Math]::Min(1000, $work.Height - 40)
            $browserArgs = @(
                '--window-position=-32000,-32000',
                "--window-size=$width,$height",
                '--disable-backgrounding-occluded-windows',
                '--disable-renderer-backgrounding',
                '--disable-background-timer-throttling',
                '--disable-features=CalculateNativeWinOcclusion'
            ) + $browserArgs
        }
    }
    $foreground = [CrawlWindow]::GetForegroundWindow()
    $null = Start-Process -FilePath $exe -ArgumentList $browserArgs -WindowStyle $windowStyle `
        -RedirectStandardError (Join-Path $LogDir 'browser.log') `
        -RedirectStandardOutput (Join-Path $LogDir 'browser.out.log')
    Set-Content -Path $BrowserModeFile -Value $Browser -NoNewline

    if (Wait-Url "http://127.0.0.1:$ChromePort/json/version" 15) {
        $proc = Get-Browser
        if ($proc) { Set-Content -Path (Get-PidFile 'browser') -Value $proc.Id -NoNewline }
        if ($proc -and $Browser -eq 'hidden') { Hide-BrowserWindow $proc $foreground }
        Write-Host "  browser up   ($(Split-Path $exe -Leaf), $Browser, DevTools on 127.0.0.1:$ChromePort)"
    } else {
        Write-Warning "Browser did not open port $ChromePort. See logs\browser.log. crw will still serve plain HTML pages."
    }
}

# The DevTools filter between crw and Chrome (see filter\CdpFilter.cs). It drops crw's
# injected disguise script and User-Agent override so Chrome shows its real fingerprint.
# Returns the port crw should connect to.
function Start-Filter {
    if (-not (Test-Path $FilterExe)) {
        Write-Warning "Missing $FilterExe (run .\setup.ps1). crw will talk to Chrome directly and inject its own disguise."
        return $ChromePort
    }
    if (Get-Tracked 'cdp-filter' @('cdp-filter')) {
        Write-Host "  filter already running"
        return $CdpPort
    }
    Assert-PortFree $CdpPort 'the DevTools filter'
    $filterArgs = @('--listen', $CdpPort, '--upstream', $ChromePort, '--log', "`"$(Join-Path $LogDir 'cdp-filter.log')`"")
    if ($FilterDrop) { $filterArgs += @('--drop', $FilterDrop) }
    $proc = Start-Process -FilePath $FilterExe -WindowStyle Hidden -PassThru -ArgumentList $filterArgs
    Set-Content -Path (Get-PidFile 'cdp-filter') -Value $proc.Id -NoNewline
    if (-not (Wait-Url "http://127.0.0.1:$CdpPort/json/version" 10)) {
        throw "The DevTools filter did not start on port $CdpPort. See logs\cdp-filter.log."
    }
    Write-Host "  filter up    (127.0.0.1:$CdpPort -> Chrome)"
    return $CdpPort
}

function Start-Crw([int]$DevToolsPort) {
    if (Get-Tracked 'crw-server' @('crw-server')) {
        Write-Host "  crw-server already running"
        return
    }
    if (-not (Test-Path $CrwExe)) { throw "Missing $CrwExe. Run .\setup.ps1 first to download fastCRW." }
    Assert-PortFree $ApiPort 'crw-server'

    # Environment variables override config.local.toml, so the ports live in one place (this file).
    $env:CRW_SERVER__HOST = '127.0.0.1'
    $env:CRW_SERVER__PORT = "$ApiPort"
    $env:CRW_RENDERER__CHROME__WS_URL = "ws://127.0.0.1:$DevToolsPort/"

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

function Start-LocalEngine {
    try {
        Start-Browser
        $devToolsPort = Start-Filter
        Start-Crw $devToolsPort
    } catch {
        # Don't leave a half-started setup behind (e.g. a browser with no server).
        Stop-Tracked 'crw-server' @('crw-server')
        Stop-Tracked 'cdp-filter' @('cdp-filter')
        Stop-Browser
        throw
    }
}

# --- Docker engine --------------------------------------------------------------
# Runs a docker command and returns its output, throwing with that output if it fails.
# (A simple function, so arguments like "-f" pass straight through in $args.)
function Invoke-Docker {
    $ErrorActionPreference = 'Continue'   # docker writes progress to stderr
    $out = & docker @args 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed: $($out.Trim())" }
    $out
}

function Invoke-Compose { Invoke-Docker compose -f $ComposeFile @args }

function Test-DockerDaemon {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    $ErrorActionPreference = 'Continue'
    $null = & docker info --format '{{.ServerVersion}}' 2>&1
    return $LASTEXITCODE -eq 0
}

function Test-DockerEngineRunning {
    if (-not (Test-DockerDaemon)) { return $false }
    $ErrorActionPreference = 'Continue'
    $ids = & docker compose -f $ComposeFile ps -q 2>$null
    return [bool]$ids
}

function Start-DockerDesktop {
    if (Test-DockerDaemon) { return }
    $desktop = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $desktop)) { throw "Docker isn't running and Docker Desktop wasn't found. Start Docker, or use the local engine." }
    Write-Host "  starting Docker Desktop..."
    Start-Process $desktop
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) {
        if (Test-DockerDaemon) { return }
        Start-Sleep -Seconds 3
    }
    throw "Docker Desktop didn't become ready within 3 minutes."
}

# A random secret for SearXNG, created once in docker\.env.
function Initialize-DockerEnv {
    $envFile = Join-Path $DockerDir '.env'
    if (Test-Path $envFile) { return }
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $hex = {
        param([int]$Bytes)
        $buf = New-Object byte[] $Bytes
        $rng.GetBytes($buf)
        -join ($buf | ForEach-Object { $_.ToString('x2') })
    }
    Set-Content -Path $envFile -Encoding ascii -Value "SEARXNG_SECRET_KEY=$(& $hex 32)"
}

function Start-DockerEngine {
    Start-DockerDesktop
    Initialize-DockerEnv
    $ErrorActionPreference = 'Continue'
    $null = & docker image inspect $DockerImage 2>&1
    $ErrorActionPreference = 'Stop'
    if ($LASTEXITCODE -ne 0) {
        throw "The Docker engine isn't set up yet. Run .\setup.ps1 -Docker once (the first build takes a while)."
    }
    Assert-PortFree $ApiPort 'the Docker engine'

    # The Docker crw renders with the host's real Chrome, through the DevTools filter.
    try {
        Start-Browser
        $devToolsPort = Start-Filter
        $env:CRW_CDP_PORT = "$devToolsPort"
        $realUa = Get-BrowserUserAgent
        if ($realUa) { $env:CRW_USER_AGENT = $realUa }

        Write-Host "  starting containers..."
        $null = Invoke-Compose up -d --no-build
        if (-not (Wait-Url "$ApiUrl/health" 120)) {
            throw "The Docker engine didn't become healthy within 2 minutes. See: docker compose -f docker\compose.yml logs crw"
        }
    } catch {
        Stop-DockerEngine
        Stop-Tracked 'cdp-filter' @('cdp-filter')
        Stop-Browser
        throw
    }
    Write-Host "  docker engine up ($ApiUrl)"
}

function Stop-DockerEngine {
    if (Test-DockerEngineRunning) {
        $null = Invoke-Compose down
        Write-Host "  stopped docker engine"
    }
}

function Get-RunningEngine {
    $engine = Get-Content $EngineFile -Raw -ErrorAction SilentlyContinue
    if ($engine) { return $engine.Trim() }
    return $null
}

# --- Start / stop / status ------------------------------------------------------
function Invoke-Start {
    New-Item -ItemType Directory -Force -Path $RunDir, $LogDir | Out-Null
    $engine = $Engine
    if (-not $engine) { $engine = Get-RunningEngine }
    if (-not $engine) { $engine = 'local' }
    $running = Get-RunningEngine
    if ($running -and $running -ne $engine) { Invoke-Stop }   # switching engines

    Write-Host "Starting crawler ($engine engine)..."
    if ($engine -eq 'docker') {
        Start-DockerEngine
    } else {
        Start-LocalEngine
    }
    Set-Content -Path $EngineFile -Value $engine -NoNewline
    Write-Host ""
    Write-Host "Ready. API:  $ApiUrl  (Firecrawl-compatible: /v1/scrape, /v1/crawl, /v1/map)"
    Write-Host "Try:         .\crawl.ps1 scrape https://example.com"
    Write-Host "Stop with:   .\crawl.ps1 stop   (or double-click stop.cmd)"
}

function Invoke-Stop {
    Write-Host "Stopping crawler..."
    Stop-Tracked 'crw-server' @('crw-server')
    Stop-Tracked 'cdp-filter' @('cdp-filter')
    Stop-Browser
    Stop-DockerEngine
    Remove-Item $EngineFile -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped."
}

function Invoke-Status {
    $docker = (Get-RunningEngine) -eq 'docker'
    if ($docker) {
        $health = if (Test-Url "$ApiUrl/health") { 'healthy' } else { 'NOT responding' }
        Write-Host "engine     : docker, $health at $ApiUrl"
        if (Test-DockerDaemon) { Write-Host (Invoke-Compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}').TrimEnd() }
    }
    $crw = Get-Tracked 'crw-server' @('crw-server')
    $browserProc = Get-Browser

    if ($crw) {
        $mb = [math]::Round($crw.WorkingSet64 / 1MB, 1)
        $health = if (Test-Url "$ApiUrl/health") { 'healthy' } else { 'NOT responding' }
        Write-Host "crw-server : running, PID $($crw.Id), $mb MB, $health at $ApiUrl"
    } elseif (-not $docker) {
        Write-Host "crw-server : stopped"
    }

    if ($browserProc) {
        $cdp = if (Test-Url "http://127.0.0.1:$ChromePort/json/version") { 'DevTools ok' } else { 'DevTools NOT responding' }
        $mode = Get-Content $BrowserModeFile -Raw -ErrorAction SilentlyContinue
        Write-Host "browser    : running, PID $($browserProc.Id), $mode, $cdp on port $ChromePort"
    } else {
        Write-Host "browser    : stopped"
    }

    $filter = Get-Tracked 'cdp-filter' @('cdp-filter')
    if ($filter) {
        $ok = if (Test-Url "http://127.0.0.1:$CdpPort/json/version") { 'ok' } else { 'NOT responding' }
        Write-Host "filter     : running, PID $($filter.Id), $ok on port $CdpPort"
    } else {
        Write-Host "filter     : stopped"
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
        'restart' {
            $previous = Get-RunningEngine
            if (-not $Engine -and $previous) { $Engine = $previous }
            Invoke-Stop
            Invoke-Start
        }
        'status'  { Invoke-Status }
        'logs'    {
            if ((Get-RunningEngine) -eq 'docker') {
                & docker compose -f $ComposeFile logs -f --tail 40 crw
            } else {
                Get-Content (Join-Path $LogDir 'crw-server.log') -Tail 40 -Wait
            }
        }
        'scrape'  { Invoke-Scrape }
    }
} catch {
    # Saved so the tray app can show why a start or stop failed.
    New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    Set-Content -Path $LastErrorFile -Value $_.Exception.Message
    throw
}
