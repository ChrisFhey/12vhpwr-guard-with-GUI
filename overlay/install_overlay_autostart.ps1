# Installs the overlay to start automatically at user logon, unprivileged.
#
# Deliberately separate from guard/install.ps1: the guard's Task Scheduler entry runs
# elevated (RunLevel Highest) so it can lock GPU clocks and drop the power limit; the
# overlay never needs elevation (it only reads status.json and writes
# pending_settings.json), and giving it a Task Scheduler entry or admin rights would
# widen its footprint for no reason. A Startup-folder shortcut is the normal,
# unprivileged way to autostart a per-user app on Windows.
#
# Run this from a normal (non-admin) PowerShell prompt in the overlay/ folder.
#
# -NoLaunch: skip starting the overlay immediately after installing the autostart
# shortcut (used by overlay_uninstaller.bat's reinstall-safety-net path, and useful
# for anyone scripting this who wants the shortcut without an instance popping up).
param(
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"

# Same token-based elevation check guard/install.ps1 and gpu_mitigation.py use (more
# reliable than the "net session" trick some batch installers use, and consistent
# with the rest of this project). The overlay must never run elevated - installing
# its autostart shortcut from an elevated shell would make Explorer's Startup-folder
# launch inherit that elevation at every future logon too.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if ($IsAdmin) {
    Write-Error "This is running with administrator rights. The overlay does not need admin rights and should not run elevated. Re-run overlay_installer.bat from a normal (non-administrator) Command Prompt."
    exit 1
}

$overlayDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonw = (Get-Command pythonw.exe -ErrorAction SilentlyContinue).Source
if (-not $pythonw) {
    $python = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
    if ($python) {
        $pythonw = Join-Path (Split-Path -Parent $python) "pythonw.exe"
    }
}
if (-not $pythonw -or -not (Test-Path $pythonw)) {
    Write-Error "pythonw.exe not found. Install Python 3.10+ and ensure it is on PATH."
    exit 1
}

function New-OverlayShortcut([string]$Path) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $pythonw
    $shortcut.Arguments = '"' + (Join-Path $overlayDir "overlay_app.py") + '"'
    $shortcut.WorkingDirectory = $overlayDir
    $shortcut.Description = "12VHPWR Guard overlay (unprivileged, no admin rights needed)"
    $shortcut.Save()
}

$startupDir = [Environment]::GetFolderPath("Startup")
$startupShortcut = Join-Path $startupDir "12VHPWR Guard Overlay.lnk"
New-OverlayShortcut $startupShortcut
Write-Output "Installed autostart shortcut: $startupShortcut"
Write-Output "The overlay will start automatically at every future logon."

# Separate shortcut in the Start Menu so closing the overlay's window (its X button
# fully exits the process, by design - see overlay_app.py) doesn't strand the user
# with no way back short of logging off. This is the same relaunch path as any other
# ordinary app: search "12VHPWR Guard Overlay" in the Start Menu.
$startMenuDir = [Environment]::GetFolderPath("Programs")
$startMenuShortcut = Join-Path $startMenuDir "12VHPWR Guard Overlay.lnk"
New-OverlayShortcut $startMenuShortcut
Write-Output "Installed Start Menu shortcut: $startMenuShortcut"
Write-Output "If you ever close the overlay, reopen it by searching '12VHPWR Guard Overlay' in the Start Menu."

# A third copy right here in overlay/ too, for anyone who navigates back to the
# install folder rather than using the Start Menu - a normal, double-clickable
# shortcut instead of having to know overlay_app.py needs pythonw.exe to run silently.
$localShortcut = Join-Path $overlayDir "12VHPWR Guard Overlay.lnk"
New-OverlayShortcut $localShortcut
Write-Output "Installed local shortcut: $localShortcut"

if (-not $NoLaunch) {
    # Check for an already-running instance first: launching a second one would just
    # sit on top of (or behind) the first, both polling the same status.json for no
    # benefit - confusing on a first run, not additive.
    $alreadyRunning = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*overlay_app.py*" }
    if ($alreadyRunning) {
        Write-Output "Overlay is already running (PID $($alreadyRunning[0].ProcessId)) - not starting a second copy."
    } else {
        Write-Output "Starting the overlay now..."
        Start-Process -FilePath $pythonw -ArgumentList "`"$(Join-Path $overlayDir 'overlay_app.py')`"" -WorkingDirectory $overlayDir
    }
}
