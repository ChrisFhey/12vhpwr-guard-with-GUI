# 12VHPWR Guard - Portable Installer
$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Err "Administrator rights required (Task Scheduler / Event Log registration)."
    Write-Err "Right-click install.bat and choose 'Run as administrator'."
    exit 1
}

$BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptName = "hwinfo_12vhpwr_guard.py"
$ScriptPath = Join-Path $BaseDir $ScriptName
$VenvDir = Join-Path $BaseDir "venv"
$PyExe = Join-Path $VenvDir "Scripts\python.exe"
$PywExe = Join-Path $VenvDir "Scripts\pythonw.exe"
$ReqPath = Join-Path $BaseDir "requirements.txt"
$ConfigPath = Join-Path $BaseDir "config.ini"
$LogsDir = Join-Path $BaseDir "logs"

$TaskName = "12VHPWR Guard"

if (!(Test-Path $ScriptPath)) { Write-Err "Missing script."; exit 1 }

# Functional check: Get-Command also matches the Microsoft Store alias stub, which
# then does nothing useful. Running the interpreter proves it exists and is new enough.
# Done before anything is created so a failed check leaves no litter behind.
& python -c "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Err "Python 3.10+ not found on PATH."
    Write-Err "Install from https://www.python.org/downloads/ and tick 'Add python.exe to PATH'."
    exit 1
}

if (!(Test-Path $LogsDir)) { New-Item -ItemType Directory -Path $LogsDir | Out-Null }

if (!(Test-Path $ConfigPath)) {
@"
[Settings]
threshold_amps = 9.5
sustained_seconds_required = 10
sensor_backend = auto
response_mode = tiered
"@ | Set-Content -Path $ConfigPath -Encoding UTF8
}

if (!(Test-Path $PyExe)) {
    & python -m venv $VenvDir
}

& $PyExe -m pip install --upgrade pip
& $PyExe -m pip install -r $ReqPath

try { & $PyExe -m pywin32_postinstall -install } catch {}

# Task and Event Log definitions are shared with the packaged installer.
. (Join-Path $BaseDir "guard_task.ps1")

Register-GuardEventSource

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Write-Info "Existing install found - stopping the running guard to upgrade it."
}

$UserId = "$env:USERDOMAIN\$env:USERNAME"
Register-GuardTask -Execute $PywExe -Argument "`"$ScriptPath`"" -WorkingDirectory $BaseDir -UserId $UserId

$startNow = Read-Host "Start 12VHPWR Guard now? (y/N)"
if ($startNow -match '^(y|yes)$') {
    Start-ScheduledTask -TaskName $TaskName
}

Write-Info "Install complete."
