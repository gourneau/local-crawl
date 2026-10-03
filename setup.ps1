<#
.SYNOPSIS
  Download the fastCRW Windows binaries into bin\ and verify their SHA-256 checksums.

.DESCRIPTION
  Fetches crw-server, crw (CLI) and crw-mcp from the official fastCRW GitHub release,
  checks each zip against the release's SHA256SUMS file, and unpacks the .exe files
  into bin\. Safe to re-run; pass -Version to upgrade or pin a different release.

.EXAMPLE
  .\setup.ps1
  .\setup.ps1 -Version 0.37.2
  .\setup.ps1 -Docker     # also prepare the Docker engine (pulls images, builds crw; ~15 min first time)
#>
param(
    [string]$Version = '0.37.2',

    # Also pull the Docker engine's images and build its crw image (with Camoufox).
    [switch]$Docker
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # the progress bar makes downloads very slow in PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = $PSScriptRoot
$Bin  = Join-Path $Root 'bin'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$Base = "https://github.com/fastcrw/crw/releases/download/v$Version"
$Temp = Join-Path ([IO.Path]::GetTempPath()) "crw-setup-$Version"

$running = Get-Process crw-server, cdp-filter -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path.StartsWith($Bin, [StringComparison]::OrdinalIgnoreCase) }
if ($running) { throw "The crawler is running from this folder. Stop it first: .\crawl.ps1 stop" }

New-Item -ItemType Directory -Force -Path $Bin, $Temp | Out-Null

Write-Host "fastCRW v$Version (win32-$Arch)"
$sumsFile = Join-Path $Temp 'SHA256SUMS'
Invoke-WebRequest "$Base/SHA256SUMS" -OutFile $sumsFile -UseBasicParsing
$sums = @{}
foreach ($line in Get-Content $sumsFile) {
    $parts = $line.Trim() -split '\s+\*?', 2
    if ($parts.Count -eq 2) { $sums[$parts[1]] = $parts[0].ToLower() }
}

foreach ($name in 'crw-server', 'crw', 'crw-mcp') {
    $zip = "$name-win32-$Arch.zip"
    if (-not $sums.ContainsKey($zip)) { throw "$zip is not listed in SHA256SUMS for v$Version." }

    $zipPath = Join-Path $Temp $zip
    Write-Host "  downloading $zip"
    Invoke-WebRequest "$Base/$zip" -OutFile $zipPath -UseBasicParsing

    $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $sums[$zip]) { throw "Checksum mismatch for $zip. Expected $($sums[$zip]), got $actual." }

    $unpacked = Join-Path $Temp $name
    Expand-Archive -Path $zipPath -DestinationPath $unpacked -Force
    Get-ChildItem $unpacked -Recurse -Filter '*.exe' | Copy-Item -Destination $Bin -Force
    Write-Host "  verified and installed $name.exe"
}

Remove-Item $Temp -Recurse -Force -ErrorAction SilentlyContinue

# The DevTools filter (filter\CdpFilter.cs), built with the C# compiler that ships with Windows.
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /target:winexe /optimize+ /out:"$(Join-Path $Bin 'cdp-filter.exe')" `
    /reference:System.Web.Extensions.dll (Join-Path $Root 'filter\CdpFilter.cs')
if ($LASTEXITCODE -ne 0) { throw "Building the DevTools filter failed (csc exit code $LASTEXITCODE)." }
Write-Host "  built cdp-filter.exe"

if ($Docker) {
    $compose = Join-Path $Root 'docker\compose.yml'
    $ErrorActionPreference = 'Continue'   # docker writes progress to stderr
    Write-Host "Docker engine: pulling images..."
    & docker compose -f $compose pull --ignore-buildable
    if ($LASTEXITCODE -ne 0) { throw "Pulling Docker images failed. Is Docker Desktop running?" }
    Write-Host "Docker engine: building crw with the Camoufox tier (the first build takes a while)..."
    & docker compose -f $compose build crw
    if ($LASTEXITCODE -ne 0) { throw "Building the crw Docker image failed." }
    $ErrorActionPreference = 'Stop'
    Write-Host "  Docker engine ready. Start it with: .\crawl.ps1 start -Engine docker"
}

Write-Host ""
Write-Host "Done. Next: .\crawl.ps1 start   (or build the tray app: .\tray\install.ps1)"
