<#
.SYNOPSIS
  Build LocalCrawler.exe (the tray launcher) and add Desktop and Start Menu shortcuts.

.DESCRIPTION
  Uses the C# compiler that ships with Windows (.NET Framework 4.x), so nothing
  needs to be installed. Safe to re-run after editing the .cs files.

.PARAMETER BuildOnly
  Only build LocalCrawler.exe: no shortcuts, and don't close or launch the tray app.
#>
param(
    [switch]$BuildOnly
)
$ErrorActionPreference = 'Stop'

$Here = $PSScriptRoot
$Root = Split-Path $Here -Parent
$Exe  = Join-Path $Root 'LocalCrawler.exe'
$Ico  = Join-Path $Here 'crawler.ico'
$Csc  = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

# Close a running copy so its exe can be replaced. This only closes the tray icon;
# the crawler itself keeps running.
if (-not $BuildOnly) {
    Get-Process LocalCrawler -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
}

# --- App icon: render the globe at several sizes into a PNG-based .ico ----------
Add-Type -Path (Join-Path $Here 'GlobeArt.cs') -ReferencedAssemblies System.Drawing
$sizes = 16, 24, 32, 48, 64, 128, 256
$images = foreach ($size in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    [GlobeArt]::Draw($g, $size, [System.Drawing.Color]::FromArgb(9, 105, 218))
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}

$writer = New-Object System.IO.BinaryWriter ([System.IO.File]::Create($Ico))
try {
    $writer.Write([uint16]0)              # reserved
    $writer.Write([uint16]1)              # type: icon
    $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = [byte]($sizes[$i] % 256)   # 256 is stored as 0
        $writer.Write($dim); $writer.Write($dim)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length)
        $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($img in $images) { $writer.Write([byte[]]$img) }
} finally {
    $writer.Close()
}

# --- Compile ------------------------------------------------------------------
& $Csc /nologo /target:winexe /optimize+ /out:"$Exe" /win32icon:"$Ico" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    (Join-Path $Here 'LocalCrawlerTray.cs') (Join-Path $Here 'GlobeArt.cs')
if ($LASTEXITCODE -ne 0) { throw "Compile failed (csc exit code $LASTEXITCODE)." }
Write-Host "Built $Exe"
if ($BuildOnly) { return }

# --- Shortcuts ----------------------------------------------------------------
$shell = New-Object -ComObject WScript.Shell
foreach ($folder in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) {
    $path = Join-Path $folder 'Local Crawler.lnk'
    $link = $shell.CreateShortcut($path)
    $link.TargetPath = $Exe
    $link.WorkingDirectory = $Root
    $link.IconLocation = "$Exe,0"
    $link.Description = 'Start and stop the local web crawler'
    $link.Save()
    Write-Host "Shortcut: $path"
}

Start-Process $Exe
Write-Host "Started. Look for the globe icon in the system tray."
