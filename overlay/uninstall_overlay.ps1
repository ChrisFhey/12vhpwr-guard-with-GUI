# Removes the overlay's autostart, Start Menu, and local shortcuts, and stops any
# running instance.
#
# Deliberately separate from guard/uninstall.ps1 (which unregisters the elevated
# Task Scheduler entry) - the overlay was never installed as a scheduled task, only
# as three plain shortcuts, so this only ever touches those and any currently-running
# pythonw.exe overlay_app.py process.

$overlayDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupDir = [Environment]::GetFolderPath("Startup")
$startMenuDir = [Environment]::GetFolderPath("Programs")
$shortcuts = @(
    (Join-Path $startupDir "12VHPWR Guard Overlay.lnk"),
    (Join-Path $startMenuDir "12VHPWR Guard Overlay.lnk"),
    (Join-Path $overlayDir "12VHPWR Guard Overlay.lnk")
)

$anyFailed = $false

foreach ($shortcutPath in $shortcuts) {
    if (-not (Test-Path $shortcutPath)) {
        Write-Output "Shortcut not found (already removed, or never installed): $shortcutPath"
        continue
    }

    # Explicit try/catch rather than relying on $ErrorActionPreference: a failure here
    # (locked file, permissions) must be reported and must not silently abort the rest
    # of the script (stopping the running process still matters even if a shortcut
    # can't be deleted this time).
    try {
        Remove-Item $shortcutPath -Force -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Could not remove shortcut: $shortcutPath ($_)" -ForegroundColor Red
        $anyFailed = $true
        continue
    }

    # Verify rather than trust: Remove-Item not throwing is not automatically proof
    # the file is gone (e.g. some sync/AV tools recreate a file after a delete race).
    if (Test-Path $shortcutPath) {
        Write-Host "[ERROR] Shortcut still exists after removal attempt: $shortcutPath" -ForegroundColor Red
        $anyFailed = $true
    } else {
        Write-Output "Removed shortcut: $shortcutPath"
    }
}

# Stop first, don't just leave it running until the user logs off: matches
# guard/uninstall.ps1's own reasoning for stopping before unregistering.
$running = Get-CimInstance Win32_Process -Filter "Name='pythonw.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*overlay_app.py*" }

if ($running) {
    foreach ($proc in $running) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Output "Stopped running overlay (PID $($proc.ProcessId))."
        } catch {
            Write-Host "[ERROR] Could not stop PID $($proc.ProcessId): $_" -ForegroundColor Red
            $anyFailed = $true
        }
    }
} else {
    Write-Output "No running overlay instance found."
}

if ($anyFailed) {
    Write-Host "[ERROR] Overlay uninstall did NOT fully succeed - see errors above. It may still autostart." -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Confirmed: overlay shortcuts removed and no instance running. It will not autostart." -ForegroundColor Green
Write-Output "The 12VHPWR Guard safety engine (guard/) is untouched - uninstall that separately with"
Write-Output "guard\uninstall.bat if you want to remove it too."
