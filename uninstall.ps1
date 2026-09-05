# Combined uninstaller: removes both the guard (Task Scheduler entry, Event Log
# source) and the overlay (all 3 shortcuts, running process), in one elevated script.
#
# Unlike installing, removing files/shortcuts is not privilege-sensitive - deleting
# a .lnk or stopping a process you own works the same whether elevated or not. So
# there's no equivalent problem here to the installer's "can't launch unelevated
# from an elevated session" issue: this script can safely call BOTH
# guard\uninstall.ps1 and overlay\uninstall_overlay.ps1 directly, unmodified.
#
# Run this by double-clicking uninstall.bat (NOT uninstall.ps1 directly), which
# triggers the UAC prompt for you.

$ErrorActionPreference = "Continue"  # keep going through step 2 even if step 1 has warnings

function Write-Info($msg) { Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Err "Administrator rights required to remove the guard's Task Scheduler entry."
    Write-Err "Right-click uninstall.bat and choose 'Run as administrator'."
    Write-Err "Nothing was removed."
    exit 1
}

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$GuardUninstallScript = Join-Path $RootDir "guard\uninstall.ps1"
$OverlayUninstallScript = Join-Path $RootDir "overlay\uninstall_overlay.ps1"

$AnyFailed = $false

Write-Info "=== Step 1 of 2: Removing the guard ==="
if (Test-Path $GuardUninstallScript) {
    & $GuardUninstallScript
    # Verify the actual outcome rather than trust the exit code - same reasoning as
    # install.ps1: guard/uninstall.ps1 does call exit 1 on its failure paths (good),
    # but confirming the task is actually gone is the one check that can't be fooled
    # by anything upstream of it.
    $taskGone = -not [bool](Get-ScheduledTask -TaskName "12VHPWR Guard" -ErrorAction SilentlyContinue)
    if (-not $taskGone) {
        Write-Err "Guard's scheduled task still exists after running its uninstaller. See errors above."
        $AnyFailed = $true
    }
} else {
    Write-Err "Could not find guard\uninstall.ps1 - skipping guard removal."
    $AnyFailed = $true
}

Write-Info ""
Write-Info "=== Step 2 of 2: Removing the overlay ==="
if (Test-Path $OverlayUninstallScript) {
    & $OverlayUninstallScript
    # Verify actual outcome rather than $LASTEXITCODE: overlay/uninstall_overlay.ps1
    # never calls a native .exe, only PowerShell cmdlets, so $LASTEXITCODE after
    # calling it reflects whatever ran before this script even started (stale), not
    # this script's own success or failure - checking it here would risk a false
    # positive/negative unrelated to what actually happened.
    $overlayDir = Join-Path $RootDir "overlay"
    $remainingShortcuts = @(
        (Join-Path ([Environment]::GetFolderPath("Startup")) "12VHPWR Guard Overlay.lnk"),
        (Join-Path ([Environment]::GetFolderPath("Programs")) "12VHPWR Guard Overlay.lnk"),
        (Join-Path $overlayDir "12VHPWR Guard Overlay.lnk")
    ) | Where-Object { Test-Path $_ }
    $overlayStillRunning = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*overlay_app.py*" }

    if ($remainingShortcuts -or $overlayStillRunning) {
        Write-Err "Overlay removal incomplete. See errors above."
        if ($remainingShortcuts) { Write-Err "Remaining shortcuts: $($remainingShortcuts -join ', ')" }
        if ($overlayStillRunning) { Write-Err "Overlay is still running." }
        $AnyFailed = $true
    }
} else {
    Write-Err "Could not find overlay\uninstall_overlay.ps1 - skipping overlay removal."
    $AnyFailed = $true
}

Write-Info ""
if ($AnyFailed) {
    Write-Err "=== Uninstall did NOT fully succeed - see errors above ==="
    exit 1
}

Write-Info "=== Uninstall complete: guard and overlay both confirmed removed ==="
