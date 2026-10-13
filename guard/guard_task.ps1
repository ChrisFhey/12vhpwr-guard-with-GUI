# Shared definition of the guard's elevated logon task.
#
# Dot-sourced by guard/install.ps1 (script install) and installer/setup_helper.ps1
# (packaged install) so both register exactly the same trigger, principal and
# restart settings. The guard's own autostart toggle only enables/disables this task
# by name; it never recreates it.

$GuardTaskName = "12VHPWR Guard"
$GuardEventSource = "12VHPWR Guard"

function Register-GuardTask {
    param(
        [Parameter(Mandatory)] [string]$Execute,
        [string]$Argument,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [Parameter(Mandatory)] [string]$UserId
    )

    # Upgrades: a still-running guard would keep the OLD code alive and hold the
    # single-instance mutex against the new one, so the upgrade would not take effect
    # until the next reboot. Stop it first; on a fresh install this is a no-op.
    $Existing = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
    if ($Existing) {
        try { Stop-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue } catch {}
    }

    try {
        Unregister-ScheduledTask -TaskName $GuardTaskName -Confirm:$false -ErrorAction SilentlyContinue
    } catch {}

    if ($Argument) {
        $Action = New-ScheduledTaskAction -Execute $Execute -Argument $Argument -WorkingDirectory $WorkingDirectory
    } else {
        $Action = New-ScheduledTaskAction -Execute $Execute -WorkingDirectory $WorkingDirectory
    }
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
    # RestartCount is deliberately high: a watchdog that gives up after a few crashes
    # stops protecting the card exactly when something is already going wrong.
    $Settings = New-ScheduledTaskSettingsSet -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

    # Without this the task defaults to a 72-hour limit and Task Scheduler kills the guard
    # after 3 days of uptime. A time-limit stop is not a "failure", so RestartCount never fires.
    $Settings.ExecutionTimeLimit = "PT0S"

    Register-ScheduledTask -TaskName $GuardTaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings | Out-Null
}

function Register-GuardEventSource {
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($GuardEventSource)) {
            New-EventLog -LogName Application -Source $GuardEventSource
        }
    } catch {}
}
