$TaskName = "12VHPWR Guard"
$EventSource = "12VHPWR Guard"

# Removing the scheduled task needs administrator rights - Unregister-ScheduledTask
# fails with "Access is denied" without them (verified). The old version of this
# script used -ErrorAction SilentlyContinue plus an empty catch{}, which swallowed
# that failure completely: it printed "Uninstalled." even when nothing was actually
# removed, and the task kept relaunching the guard at every subsequent logon. This
# version checks elevation up front and verifies removal actually happened afterward,
# so a failure is impossible to miss.
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "[ERROR] Administrator rights required to remove the Task Scheduler entry." -ForegroundColor Red
    Write-Host "[ERROR] Right-click uninstall.bat and choose 'Run as administrator'." -ForegroundColor Red
    Write-Host "[ERROR] Nothing was removed - the guard will still run at your next logon." -ForegroundColor Red
    exit 1
}

$Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $Existing) {
    Write-Host "[INFO] No '$TaskName' scheduled task found (already removed, or never installed)." -ForegroundColor Cyan
} else {
    # Stop first: unregistering alone leaves the running pythonw process alive until logoff.
    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    } catch {
        Write-Host "[WARN] Could not stop the running task before removing it: $_" -ForegroundColor Yellow
        Write-Host "[WARN] Continuing with removal anyway - a running instance will exit once unregistered or at next logoff." -ForegroundColor Yellow
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Failed to remove the scheduled task: $_" -ForegroundColor Red
        Write-Host "[ERROR] The guard WILL still run at your next logon. Try again from an elevated prompt." -ForegroundColor Red
        exit 1
    }
}

# Verify removal actually happened rather than trusting the calls above not to have
# thrown - this is the one thing that must be true for "uninstalled" to be accurate.
Start-Sleep -Milliseconds 500
$stillThere = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($stillThere) {
    Write-Host "[ERROR] The scheduled task still exists after attempting removal. Uninstall did NOT succeed." -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Confirmed: '$TaskName' scheduled task is gone. It will not run at next logon." -ForegroundColor Green

# install.ps1 registers this via New-EventLog -LogName Application -Source $EventSource.
# Not required for "the guard won't run again" (that's the task, already handled
# above), but a real leftover otherwise - the source stays registered in
# HKLM\...\EventLog\Application forever unless explicitly removed.
try {
    if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
        Remove-EventLog -Source $EventSource -ErrorAction Stop
        if ([System.Diagnostics.EventLog]::SourceExists($EventSource)) {
            Write-Host "[ERROR] Event Log source '$EventSource' still exists after removal attempt." -ForegroundColor Red
        } else {
            Write-Host "[INFO] Confirmed: Event Log source '$EventSource' removed." -ForegroundColor Green
        }
    } else {
        Write-Host "[INFO] No Event Log source '$EventSource' found (already removed, or never registered)." -ForegroundColor Cyan
    }
} catch {
    Write-Host "[WARN] Could not remove Event Log source '$EventSource': $_" -ForegroundColor Yellow
    Write-Host "[WARN] This is cosmetic only - it does not affect whether the guard runs." -ForegroundColor Yellow
}

Write-Host "[INFO] If a tray icon is still visible (a manually started instance), right-click it and choose Exit." -ForegroundColor Cyan
