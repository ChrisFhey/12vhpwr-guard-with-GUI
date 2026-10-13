# Builds the guard and overlay executables (PyInstaller) and the setup program
# (Inno Setup 6). Run from any directory on a Windows build machine:
#
#   powershell -ExecutionPolicy Bypass -File installer\build.ps1
#
# Output: installer\Output\12VHPWR-Guard-Setup-<version>.exe
# The version comes from the VERSION file at the repository root unless -Version is given.

param(
    [string]$Version,
    # Scratch space for the build venv and PyInstaller output. Point it at a local
    # disk when the repository lives on a network/WSL share.
    [string]$BuildDir,
    # Python launcher used to create the build venv.
    [string]$Python = "py",
    [string]$Iscc,
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $BuildDir) { $BuildDir = Join-Path $PSScriptRoot "build" }
$BuildDir = [IO.Path]::GetFullPath($BuildDir)
$DistDir = Join-Path $BuildDir "dist"
$WorkDir = Join-Path $BuildDir "work"
$VenvDir = Join-Path $BuildDir "venv"

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($Arguments -join ' ') failed ($LASTEXITCODE)" }
}

if (-not $Version) { $Version = (Get-Content (Join-Path $Root "VERSION") -Raw).Trim() }
if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw "Version '$Version' must be numeric (major.minor.patch[.build]) for Windows version resources."
}
$parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
while ($parts.Count -lt 4) { $parts += 0 }
$guardAppVersion = (Select-String -Path (Join-Path $Root "guard\hwinfo_12vhpwr_guard.py") -Pattern '^APP_VERSION = "(.+)"').Matches[0].Groups[1].Value
Step "Building $Version (guard APP_VERSION $guardAppVersion)"

Step "Preparing build venv in $VenvDir"
$VenvPy = Join-Path $VenvDir "Scripts\python.exe"
$pyArgs = @("-m", "venv", $VenvDir)
if ((Split-Path -Leaf $Python) -match '^py(\.exe)?$') { $pyArgs = @("-3") + $pyArgs }
if (!(Test-Path $VenvPy)) { Invoke-Checked $Python $pyArgs }
Invoke-Checked $VenvPy @("-m", "pip", "install", "--disable-pip-version-check", "-q",
    "-r", (Join-Path $Root "guard\requirements.txt"),
    "-r", (Join-Path $PSScriptRoot "requirements-build.txt"))

function Write-VersionFile([string]$Path, [string]$Description, [string]$ExeName) {
    $tuple = "($($parts -join ', '))"
    @"
VSVersionInfo(
  ffi=FixedFileInfo(filevers=$tuple, prodvers=$tuple, mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[
    StringFileInfo([StringTable('040904B0', [
      StringStruct('FileDescription', '$Description'),
      StringStruct('FileVersion', '$Version'),
      StringStruct('InternalName', '$ExeName'),
      StringStruct('OriginalFilename', '$ExeName.exe'),
      StringStruct('ProductName', '12VHPWR Guard'),
      StringStruct('ProductVersion', '$Version')])]),
    VarFileInfo([VarStruct('Translation', [1033, 1200])])
  ]
)
"@ | Set-Content -Path $Path -Encoding ASCII  # PyInstaller eval()s this file; no BOM
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$env:GUARD_VERSION_FILE = Join-Path $WorkDir "guard_version.txt"
$env:OVERLAY_VERSION_FILE = Join-Path $WorkDir "overlay_version.txt"
Write-VersionFile $env:GUARD_VERSION_FILE "12VHPWR Guard watchdog" "12VHPWR-Guard"
Write-VersionFile $env:OVERLAY_VERSION_FILE "12VHPWR Guard overlay" "12VHPWR-Guard-Overlay"

foreach ($spec in "guard.spec", "overlay.spec") {
    Step "PyInstaller $spec"
    Invoke-Checked $VenvPy @("-m", "PyInstaller", "--noconfirm", "--clean", "--log-level", "WARN",
        "--distpath", $DistDir, "--workpath", $WorkDir, (Join-Path $PSScriptRoot $spec))
}

Step "Verifying bundles"
# A protection module silently missing from the bundle would degrade the guard
# instead of failing, so fail the build here instead.
$pyzToc = Get-Content (Join-Path $WorkDir "guard\PYZ-00.toc") -Raw
foreach ($m in "app_paths", "astral_i2c", "gpu_mitigation", "telemetry", "hwinfo_voltage",
               "status_writer", "settings_bridge", "pystray._win32", "win32evtlogutil", "winotify") {
    if ($pyzToc -notmatch "'$([regex]::Escape($m))'") { throw "Guard bundle is missing module '$m'." }
}
$pyzToc = Get-Content (Join-Path $WorkDir "overlay\PYZ-00.toc") -Raw
foreach ($m in "overlay_paths", "overlay_settings", "overlay_theme", "overlay_app") {
    if ($pyzToc -notmatch "'$m'") { throw "Overlay bundle is missing module '$m'." }
}
# Only the public project icon may ship; never the personal astral_guard.ico.
$icons = @(Get-ChildItem $DistDir -Recurse -Filter "*.ico" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "astral_guard_public.ico" })
if ($icons) { throw "Unexpected icon files in the bundle: $($icons.FullName -join ', ')" }

if ($SkipInstaller) { Step "Done (installer skipped): $DistDir"; exit 0 }

if (-not $Iscc) {
    $Iscc = @(
        (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source,
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $Iscc) { throw "Inno Setup 6 (ISCC.exe) not found. Install it or pass -Iscc <path>." }

Step "Inno Setup"
Invoke-Checked $Iscc @("/Q", "/DAppVersion=$Version", "/DDistDir=$DistDir",
    (Join-Path $PSScriptRoot "12vhpwr_guard.iss"))
Step "Done: $(Join-Path $PSScriptRoot "Output\12VHPWR-Guard-Setup-$Version.exe")"
