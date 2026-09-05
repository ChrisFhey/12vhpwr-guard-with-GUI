# Combined installer: sets up both the guard (elevated) and the overlay's autostart
# shortcuts, in one script with a single UAC prompt.
#
# Why this can't just call overlay/install_overlay_autostart.ps1 as a second step:
# that script deliberately REFUSES to run elevated (verified: a process spawned via
# Start-Process from an elevated script inherits elevation on Windows by default -
# there is no simple way to "drop" privileges for a child process without real Win32
# API calls (CreateProcessWithTokenW against explorer.exe's token), which this project
# avoids as unnecessary complexity for a convenience feature). So this script creates
# the overlay's shortcuts directly, using the same logic, but does NOT launch the
# overlay live - a shortcut file is not privilege-sensitive to create, but actually
# starting the overlay process from here would run it elevated, which must never
# happen. You'll open it yourself once from the Start Menu after this finishes, or it
# will start automatically at your next logon either way.
#
# Run this by double-clicking install.bat (NOT install.ps1 directly), which triggers
# the UAC prompt for you.

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Err "Administrator rights required (the guard needs them for Task Scheduler / Event Log / GPU power-limit control)."
    Write-Err "Right-click install.bat and choose 'Run as administrator'."
    exit 1
}

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuardDir = Join-Path $RootDir "guard"
$OverlayDir = Join-Path $RootDir "overlay"
$GuardInstallScript = Join-Path $GuardDir "install.ps1"

if (!(Test-Path $GuardInstallScript)) {
    Write-Err "Could not find guard\install.ps1 - is this script in the project root, next to guard\ and overlay\?"
    exit 1
}

Write-Info "=== Step 1 of 2: Installing the guard (elevated) ==="
# Unmodified: this runs guard/install.ps1 exactly as if you had double-clicked
# guard\install.bat yourself - same Task Scheduler registration, same venv setup,
# same Event Log source, same "start now?" prompt. Nothing about it changes here.
#
# Verified by checking the actual outcome (the task exists), not $LASTEXITCODE:
# guard/install.ps1 only ever calls exit on its failure paths, never exit 0 on
# success, so a stale exit code from whatever native command happened to run last
# inside it (pip, pywin32_postinstall, etc.) is not a trustworthy success signal.
& $GuardInstallScript
$GuardTaskExists = [bool](Get-ScheduledTask -TaskName "12VHPWR Guard" -ErrorAction SilentlyContinue)
if (-not $GuardTaskExists) {
    Write-Err "Guard installation did not complete (no '12VHPWR Guard' scheduled task found afterward)."
    Write-Err "Check the output above for the actual failure. Stopping before touching the overlay."
    exit 1
}

Write-Info ""
Write-Info "=== Step 2 of 2: Installing the overlay's shortcuts (stays unprivileged) ==="

$pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $pythonw) {
    $python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    if ($python) {
        $pythonw = Join-Path (Split-Path -Parent $python) "pythonw.exe"
    }
}
if (-not $pythonw -or -not (Test-Path $pythonw)) {
    Write-Err "pythonw.exe not found - the guard install above should have confirmed Python already, this is unexpected."
    exit 1
}

# Creating a .lnk file is not a privilege-sensitive operation - only launching a
# process from this elevated session would be. These are the exact same three
# locations and same shortcut contents overlay/install_overlay_autostart.ps1 creates,
# duplicated here rather than calling that script because it explicitly (and
# correctly) refuses to run under an elevated session.
function New-OverlayShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $pythonw
    $shortcut.Arguments = '"' + (Join-Path $OverlayDir "overlay_app.py") + '"'
    $shortcut.WorkingDirectory = $OverlayDir
    $shortcut.Description = "12VHPWR Guard overlay (unprivileged, no admin rights needed)"
    $shortcut.Save()
}

$startupDir = [Environment]::GetFolderPath("Startup")
$startupShortcut = Join-Path $startupDir "12VHPWR Guard Overlay.lnk"
New-OverlayShortcut $startupShortcut
Write-Info "Installed autostart shortcut: $startupShortcut"

$startMenuDir = [Environment]::GetFolderPath("Programs")
$startMenuShortcut = Join-Path $startMenuDir "12VHPWR Guard Overlay.lnk"
New-OverlayShortcut $startMenuShortcut
Write-Info "Installed Start Menu shortcut: $startMenuShortcut"

$localShortcut = Join-Path $OverlayDir "12VHPWR Guard Overlay.lnk"
New-OverlayShortcut $localShortcut
Write-Info "Installed local shortcut: $localShortcut"

Write-Info ""
Write-Info "=== Install complete ==="
Write-Info "The guard will run at every future logon (or is running now if you chose 'y' above)."
Write-Info "The overlay will also start automatically at every future logon."

$startOverlayNow = Read-Host "Start the overlay now? (y/N)"
if ($startOverlayNow -match '^(y|yes)$') {
    # Launching it directly here (Start-Process, or anything else spawned from this
    # elevated session) would run it WITH administrator rights - verified on real
    # hardware that child processes inherit the parent's elevation by default on
    # Windows. The overlay must never be elevated (it only reads a status file and
    # draws a window; there is no reason for it to hold admin rights, and doing so
    # would be a pointless increase in attack surface).
    #
    # Fix: a one-shot Task Scheduler task with RunLevel=Limited (non-elevated).
    # Verified live: a process launched this way from inside an elevated script
    # comes back with TokenElevation = 0 (checked via OpenProcessToken +
    # GetTokenInformation, the same API Task Manager's own "Elevated" column uses).
    # Task Scheduler always launches at the run level the task specifies, regardless
    # of the privilege level of whatever created or triggered the task.
    $LaunchTaskName = "12VHPWR Guard Overlay Launch (temporary)"
    try {
        $LaunchAction = New-ScheduledTaskAction -Execute $pythonw -Argument "`"$(Join-Path $OverlayDir 'overlay_app.py')`"" -WorkingDirectory $OverlayDir
        $LaunchTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(5)
        $LaunchPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $LaunchTaskName -Action $LaunchAction -Trigger $LaunchTrigger -Principal $LaunchPrincipal -Force | Out-Null
        Start-ScheduledTask -TaskName $LaunchTaskName
        Start-Sleep -Seconds 2
        Write-Info "Overlay started (unprivileged)."
    } catch {
        Write-Warn "Could not start the overlay automatically: $_"
        Write-Warn "Open it yourself by searching '12VHPWR Guard Overlay' in the Start Menu."
    } finally {
        # One-shot: remove the launcher task regardless of success/failure so it
        # never lingers as a second, redundant autostart mechanism alongside the
        # Startup-folder shortcut already installed above.
        Start-Sleep -Milliseconds 500
        Unregister-ScheduledTask -TaskName $LaunchTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
} else {
    Write-Info "Open it yourself later by searching '12VHPWR Guard Overlay' in the Start Menu,"
    Write-Info "or it will start automatically at your next logon."
}
