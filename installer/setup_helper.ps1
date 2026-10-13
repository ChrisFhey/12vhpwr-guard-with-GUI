# Elevated system configuration for the packaged installer (12vhpwr_guard.iss).
#
# Inno Setup copies files; everything else - the guard's scheduled task, Event Log
# source, data-folder permissions, and stopping/restoring a running install - lives
# here so it can be read and tested on its own. Task settings come from
# guard_task.ps1, the same definition the script installer uses.
#
# Actions (exit code 0 = success):
#   Prepare    back up the current task and binaries, import a script install's
#              config and mitigation state, stop the old guard and wait until every
#              one of its processes has exited
#   Configure  data folder + ACLs, Event Log source, register the guard task, start
#              it and confirm exactly one guard is running
#   Restore    put the previous task and binaries back and confirm the guard runs
#   Cleanup    after a successful install: remove a script install's overlay
#              autostart shortcuts and running overlay, delete the Prepare backup
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
    [string]$LogFile,
    # Folders searched for a script install's overlay shortcuts. Defaults to the
    # guard user's and the current user's Startup and Start Menu folders.
    [string[]]$ShortcutDirs,
    [int]$StartTimeoutSec = 20,
    [int]$StableSec = 3
)

$ErrorActionPreference = "Stop"

$GuardExeName = "12VHPWR-Guard.exe"
$GuardExe = Join-Path $InstallDir "guard\$GuardExeName"
$BackupRoot = Join-Path $DataDir "backup"
$BackupDir = Join-Path $BackupRoot "app"
# Written only after a full copy, so Restore never mirrors a partial backup over
# an install that was never touched.
$BackupComplete = Join-Path $BackupRoot "complete"
# The task as it was before setup touched it, re-registered by Restore.
$TaskBackup = Join-Path $BackupRoot "task.xml"
# Paths of a script install found by Prepare, for Stop-Installed and Cleanup.
$LegacyFile = Join-Path $BackupRoot "legacy.json"
$RequestsDir = Join-Path $DataDir "requests"
# Crash-recovery state the guard writes next to its config.
$StateFiles = @("mitigation.active", "last_shutdown.json")

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

# True when $Text contains $Path as a whole argument, not as part of a longer path.
function Test-HasPathArg([string]$Text, [string]$Path) {
    return [bool]($Text -and $Text -match ('(?i)(^|[\s"])' + [regex]::Escape($Path) + '($|[\s"])'))
}

function Get-InstalledProcesses {
    $prefix = [IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @("12VHPWR-Guard", "12VHPWR-Guard-Overlay") -and
        $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    }
}

# Script install (guard\install.ps1): the task runs
#   <venv>\Scripts\pythonw.exe "<repo>\guard\hwinfo_12vhpwr_guard.py"
function Get-LegacyInfoFromTask {
    $task = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
    if (-not $task) { return $null }
    $script = "$($task.Actions[0].Arguments)".Trim('"', ' ')
    if ($script -notlike "*\hwinfo_12vhpwr_guard.py") { return $null }
    $guardDir = Split-Path -Parent $script
    [pscustomobject]@{
        GuardScript   = $script
        GuardDir      = $guardDir
        OverlayScript = Join-Path (Split-Path -Parent $guardDir) "overlay\overlay_app.py"
    }
}

function Get-LegacyInfo {
    if (Test-Path $LegacyFile) { return Get-Content $LegacyFile -Raw | ConvertFrom-Json }
    return $null
}

# Python processes whose command line names one of $Scripts (full paths), plus all
# their descendants - the venv launcher's real interpreter is a child process. Only
# exact script-path matches count, so unrelated Python processes are never touched.
function Get-ScriptProcessTree([string[]]$Scripts) {
    $all = @(Get-CimInstance Win32_Process)
    $set = @{}
    foreach ($p in $all) {
        if ($p.Name -notmatch '^pythonw?\.exe$') { continue }
        foreach ($s in $Scripts) {
            if (Test-HasPathArg $p.CommandLine $s) { $set[[int]$p.ProcessId] = $p }
        }
    }
    do {
        $added = $false
        foreach ($p in $all) {
            $parent = $set[[int]$p.ParentProcessId]
            # CreationDate guards against a recycled parent PID.
            if (-not $set.ContainsKey([int]$p.ProcessId) -and $parent -and $p.CreationDate -ge $parent.CreationDate) {
                $set[[int]$p.ProcessId] = $p
                $added = $true
            }
        }
    } while ($added)
    return @($set.Values)
}

function Stop-ProcessesAndWait([scriptblock]$Find, [string]$What, [int]$GraceSec = 5) {
    $grace = (Get-Date).AddSeconds($GraceSec)
    $deadline = $grace.AddSeconds(10)
    while (($procs = @(& $Find)).Count -gt 0) {
        $now = Get-Date
        if ($now -gt $deadline) {
            throw "$What still running: $(($procs | ForEach-Object { "$($_.Name) ($(if ($_.ProcessId) { $_.ProcessId } else { $_.Id }))" }) -join ', ')"
        }
        if ($now -gt $grace) {
            foreach ($p in $procs) {
                $id = if ($p.ProcessId) { $p.ProcessId } else { $p.Id }
                try { Stop-Process -Id $id -Force; Log "Terminated $What process $($p.Name) ($id)." } catch {}
            }
        }
        Start-Sleep -Milliseconds 300
    }
}

# Processes from an earlier snapshot that are still alive (same PID and start time).
function Get-Survivors($Snapshot) {
    @($Snapshot | ForEach-Object {
        $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ProcessId)" -ErrorAction SilentlyContinue
        if ($p -and $p.CreationDate -eq $_.CreationDate) { $p }
    })
}

function Stop-Installed {
    # A script install's guard: Stop-ScheduledTask ends only the venv launcher, and
    # once it is gone its interpreter can no longer be traced back to the script, so
    # take the whole tree first. The interpreter must exit, or it keeps the
    # single-instance mutex and the new guard exits at startup.
    $legacy = Get-LegacyInfo
    $legacyTree = if ($legacy) { Get-ScriptProcessTree @($legacy.GuardScript) } else { @() }
    if (Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue) {
        try { Stop-ScheduledTask -TaskName $GuardTaskName } catch { Log "Stop-ScheduledTask: $_" }
    }
    # Also catches a guard started by hand and overlays in every logon session.
    Stop-ProcessesAndWait { Get-InstalledProcesses } "installed guard/overlay" -GraceSec 0
    if ($legacy) {
        Stop-ProcessesAndWait {
            @(Get-Survivors $legacyTree) + @(Get-ScriptProcessTree @($legacy.GuardScript)) |
                Sort-Object ProcessId -Unique
        } "script-install guard"
    }
    Log "Guard and overlay stopped."
}

function Wait-GuardRunning([scriptblock]$ProcessCheck, [string]$Expect) {
    $deadline = (Get-Date).AddSeconds($StartTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $task = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
        if ($task -and "$($task.State)" -eq "Running" -and (& $ProcessCheck)) {
            # A guard that finds another instance, or crashes on start, exits within
            # a second or two; require it to still be there after a short wait.
            Start-Sleep -Seconds $StableSec
            $task = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
            if ($task -and "$($task.State)" -eq "Running" -and (& $ProcessCheck)) { return }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "The guard did not keep running after start: expected $Expect (task state: $(if ($task) { $task.State } else { 'missing' }))."
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

function Import-LegacyConfig($Legacy) {
    $config = Join-Path $DataDir "config.ini"
    $source = Join-Path $Legacy.GuardDir "config.ini"
    if ((Test-Path $config) -or !(Test-Path $source)) { return }
    Copy-Item $source $config
    Log "Imported settings from script install: $source"
}

# Copied (not moved) after the old guard has exited, so the new guard undoes a GPU
# limit the old one left behind - and the script install still has its own copy
# if setup rolls back to it.
function Import-LegacyState($Legacy) {
    foreach ($name in $StateFiles) {
        $source = Join-Path $Legacy.GuardDir $name
        $target = Join-Path $DataDir $name
        if (!(Test-Path $source)) { continue }
        if ((Test-Path $target) -and (Get-Item $target).LastWriteTime -ge (Get-Item $source).LastWriteTime) { continue }
        Copy-Item $source $target -Force
        Log "Imported $name from script install."
    }
}

function Get-ShortcutDirs {
    if ($ShortcutDirs) { return $ShortcutDirs }
    $dirs = @([Environment]::GetFolderPath("Startup"), [Environment]::GetFolderPath("Programs"))
    try {
        $sid = (New-Object Security.Principal.NTAccount (Resolve-GuardUser)).Translate([Security.Principal.SecurityIdentifier]).Value
        $profileDir = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
        if ($profileDir) {
            $programs = Join-Path $profileDir "AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
            $dirs += @((Join-Path $programs "Startup"), $programs)
        }
    } catch { Log "Could not resolve the guard user's profile: $_" }
    return @($dirs | Where-Object { $_ } | Select-Object -Unique)
}

# Only shortcuts that start Python with the script install's own overlay_app.py
# are removed, whatever they are called.
function Remove-LegacyShortcuts($Legacy) {
    $shell = New-Object -ComObject WScript.Shell
    $failed = @()
    foreach ($dir in Get-ShortcutDirs) {
        foreach ($lnk in @(Get-ChildItem -Path $dir -Filter *.lnk -File -ErrorAction SilentlyContinue)) {
            # Shell-namespace and MSI-advertised shortcuts (e.g. "File Explorer.lnk")
            # have no TargetPath, and a damaged .lnk cannot be read at all; neither is
            # ours, so skip it rather than abort the scan.
            try { $sc = $shell.CreateShortcut($lnk.FullName) } catch { continue }
            if ([IO.Path]::GetFileName("$($sc.TargetPath)") -notmatch '^pythonw?\.exe$') { continue }
            if (-not (Test-HasPathArg $sc.Arguments $Legacy.OverlayScript)) { continue }
            try {
                Remove-Item $lnk.FullName -Force
                Log "Removed script-install overlay shortcut: $($lnk.FullName)"
            } catch { $failed += $lnk.FullName }
        }
    }
    if ($failed) { throw "Could not remove: $($failed -join ', ')" }
}

function Copy-Tree([string]$From, [string]$To) {
    & robocopy.exe $From $To /MIR /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $From -> $To failed ($LASTEXITCODE)" }
}

try {
    switch ($Action) {
        "Prepare" {
            # Drop a stale backup first, so a failure below can never make Restore
            # roll back to an older state than the one installed right now.
            if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
            New-Item -ItemType Directory -Path $BackupRoot | Out-Null
            if (Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue) {
                Export-ScheduledTask -TaskName $GuardTaskName | Set-Content -Path $TaskBackup -Encoding Unicode
                Log "Backed up scheduled task '$GuardTaskName'."
            }
            $legacy = Get-LegacyInfoFromTask
            if ($legacy) {
                $legacy | ConvertTo-Json | Set-Content -Path $LegacyFile -Encoding UTF8
                Log "Script install found: $($legacy.GuardScript)"
                Import-LegacyConfig $legacy
            }
            Stop-Installed
            if ($legacy) { Import-LegacyState $legacy }
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
            Start-ScheduledTask -TaskName $GuardTaskName
            Wait-GuardRunning { @(Get-InstalledProcesses | Where-Object Name -eq "12VHPWR-Guard").Count -eq 1 } "exactly one $GuardExeName"
            Log "Guard started; exactly one instance running."
        }
        "Restore" {
            # Runs after a failed or cancelled setup that got as far as Prepare.
            $hasTask = Test-Path $TaskBackup
            $hasFiles = Test-Path $BackupComplete
            if (-not $hasTask -and -not $hasFiles) {
                Log "Nothing to restore (no previous installation)."
                exit 0
            }
            # Keep going if something refuses to stop: putting the previous task back
            # matters more, and its single-instance mutex prevents a duplicate guard.
            try { Stop-Installed } catch { Log "Stop before restore: $_" }
            if ($hasFiles) {
                Copy-Tree $BackupDir $InstallDir
                Log "Restored $InstallDir from backup."
            }
            if ($hasTask) {
                Register-ScheduledTask -TaskName $GuardTaskName -Xml (Get-Content $TaskBackup -Raw) -Force | Out-Null
                Log "Re-registered previous scheduled task '$GuardTaskName'."
            }
            Start-ScheduledTask -TaskName $GuardTaskName
            Wait-GuardRunning { $true } "the task to stay running"
            Log "Previous guard restarted and running."
        }
        "Cleanup" {
            $legacy = Get-LegacyInfo
            $problem = $null
            if ($legacy) {
                try { Remove-LegacyShortcuts $legacy } catch { $problem = "$_" }
                try {
                    Stop-ProcessesAndWait { Get-ScriptProcessTree @($legacy.OverlayScript) } "script-install overlay" -GraceSec 0
                } catch { $problem = "$problem $_".Trim() }
            }
            if (Test-Path $BackupRoot) { Remove-Item $BackupRoot -Recurse -Force }
            if ($problem) { throw $problem }
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
