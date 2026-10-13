# Elevated system configuration for the packaged installer (12vhpwr_guard.iss).
#
# Inno Setup copies files; everything else - the guard's scheduled task, Event Log
# source, data-folder permissions, and stopping/restoring a running install - lives
# here so it can be read and tested on its own. Task settings come from
# guard_task.ps1, the same definition the script installer uses.
#
# Actions (exit code 0 = success):
#   Prepare    stop the guard and overlay, back up the current binaries, import the
#              config of a script-based install if there is no installed config yet
#   Configure  data folder + ACLs, Event Log source, register and start the guard task
#   Restore    roll binaries back from the Prepare backup and restart the guard
#   Cleanup    delete the Prepare backup after a successful upgrade
#   Uninstall  stop everything, remove the task and Event Log source

param(
    [Parameter(Mandatory)]
    [ValidateSet("Prepare", "Configure", "Restore", "Cleanup", "Uninstall")]
    [string]$Action,
    [Parameter(Mandatory)] [string]$InstallDir,
    [Parameter(Mandatory)] [string]$DataDir,
    # Account the guard runs as. Defaults to the interactive console user rather than
    # the account running setup, which differs when a standard user elevates with
    # someone else's admin credentials.
    [string]$UserId,
    [string]$LogFile
)

$ErrorActionPreference = "Stop"

$GuardExeName = "12VHPWR-Guard.exe"
$OverlayExeName = "12VHPWR-Guard-Overlay.exe"
$GuardExe = Join-Path $InstallDir "guard\$GuardExeName"
$BackupRoot = Join-Path $DataDir "backup"
$BackupDir = Join-Path $BackupRoot "app"
# Written only after a full copy, so Restore never mirrors a partial backup over
# an install that was never touched.
$BackupComplete = Join-Path $BackupRoot "complete"
$RequestsDir = Join-Path $DataDir "requests"

. (Join-Path $PSScriptRoot "guard_task.ps1")

function Log($msg) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [$Action] $msg" -f (Get-Date)
    Write-Host $line
    if ($LogFile) {
        try {
            $logDir = Split-Path -Parent $LogFile
            if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
            Add-Content -Path $LogFile -Value $line -Encoding UTF8
        } catch {}
    }
}

function Get-InstalledProcesses {
    $prefix = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @("12VHPWR-Guard", "12VHPWR-Guard-Overlay") -and
        $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
}

function Stop-Installed {
    if (Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask -TaskName $GuardTaskName } catch { Log "Stop-ScheduledTask: $_" }
    }
    # Also catches a guard started by hand and overlays in every logon session.
    $deadline = (Get-Date).AddSeconds(10)
    while (($procs = @(Get-InstalledProcesses)).Count -gt 0) {
        if ((Get-Date) -gt $deadline) {
            throw "Still running after stop: $($procs | ForEach-Object { "$($_.Name) ($($_.Id))" })"
        }
        $procs | ForEach-Object { try { $_ | Stop-Process -Force } catch {} }
        Start-Sleep -Milliseconds 300
    }
    Log "Guard and overlay stopped."
}

function Resolve-GuardUser {
    if ($UserId) { return $UserId }
    try {
        $console = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($console) { return $console }
    } catch {}
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Invoke-Icacls([string[]]$IcaclsArgs) {
    & icacls.exe @IcaclsArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls $($IcaclsArgs -join ' ') failed ($LASTEXITCODE)" }
}

function Set-DataDirAcl {
    foreach ($d in @($DataDir, $RequestsDir, (Join-Path $DataDir "logs"))) {
        if (!(Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    }
    # The guard runs elevated and reads config.ini from here, so ordinary users get
    # read access only. The default ProgramData ACL would let any user create files.
    # SIDs: SYSTEM, Administrators, Users.
    Invoke-Icacls @($DataDir, "/inheritance:r", "/grant:r",
        "*S-1-5-18:(OI)(CI)F", "*S-1-5-32-544:(OI)(CI)F", "*S-1-5-32-545:(OI)(CI)RX")
    Invoke-Icacls @("$DataDir\*", "/reset", "/T", "/C", "/Q")
    # The one place the unprivileged overlay writes: pending_settings.json. The guard
    # validates and deletes it - same trust level as the tray menu's settings dialog.
    Invoke-Icacls @($RequestsDir, "/grant", "*S-1-5-32-545:(OI)(CI)M")
}

function Import-LegacyConfig {
    # Script install (guard\install.ps1): task runs pythonw.exe "<repo>\guard\hwinfo_12vhpwr_guard.py".
    $config = Join-Path $DataDir "config.ini"
    if (Test-Path $config) { return }
    $task = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return }
    $arg = "$($task.Actions[0].Arguments)".Trim('"', ' ')
    if ($arg -notlike "*hwinfo_12vhpwr_guard.py") { return }
    $legacy = Join-Path (Split-Path -Parent $arg) "config.ini"
    if (Test-Path $legacy) {
        if (!(Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
        Copy-Item $legacy $config
        Log "Imported settings from script install: $legacy"
    }
}

function Copy-Tree([string]$From, [string]$To) {
    & robocopy.exe $From $To /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $To failed ($LASTEXITCODE)" }
}

try {
    switch ($Action) {
        "Prepare" {
            # Drop a stale backup first, so a failure below can never make Restore
            # roll back to an older version than the one installed right now.
            if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
            Import-LegacyConfig
            Stop-Installed
            if (Test-Path $GuardExe) {
                Copy-Tree $InstallDir $BackupDir
                New-Item -ItemType File -Path $BackupComplete | Out-Null
                Log "Backed up $InstallDir to $BackupDir"
            }
        }
        "Configure" {
            if (!(Test-Path $GuardExe)) { throw "Missing $GuardExe" }
            Set-DataDirAcl
            Register-GuardEventSource
            $user = Resolve-GuardUser
            Register-GuardTask -Execute $GuardExe -WorkingDirectory (Split-Path -Parent $GuardExe) -UserId $user
            $task = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
            if (-not $task -or $task.Actions[0].Execute -ne $GuardExe) {
                throw "Scheduled task '$GuardTaskName' was not registered correctly."
            }
            Log "Registered '$GuardTaskName' for $user (elevated, at logon)."
            try {
                Start-ScheduledTask -TaskName $GuardTaskName
                Log "Guard started."
            } catch {
                # Not fatal: the task is in place and runs at next logon.
                Log "Could not start the guard now ($_); it will start at next logon."
            }
        }
        "Restore" {
            # Also used when setup stopped the guard and then failed or was cancelled
            # before replacing anything: then there is no backup and this only
            # restarts whatever task was registered before.
            if (Test-Path $BackupComplete) {
                Stop-Installed
                Copy-Tree $BackupDir $InstallDir
                Log "Restored $InstallDir from backup."
            }
            if (Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue) {
                Start-ScheduledTask -TaskName $GuardTaskName
                Log "Guard restarted."
            } else {
                Log "No guard task registered; nothing to restart."
            }
        }
        "Cleanup" {
            if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
        }
        "Uninstall" {
            Stop-Installed
            if (Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $GuardTaskName -Confirm:$false
            }
            if (Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue) {
                throw "Scheduled task '$GuardTaskName' still exists after removal."
            }
            Log "Removed scheduled task '$GuardTaskName'."
            try {
                if ([System.Diagnostics.EventLog]::SourceExists($GuardEventSource)) {
                    Remove-EventLog -Source $GuardEventSource
                }
            } catch { Log "Could not remove Event Log source (cosmetic): $_" }
        }
    }
    exit 0
} catch {
    Log "FAILED: $_ ($($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))"
    exit 1
}
