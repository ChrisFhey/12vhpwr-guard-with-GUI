# Failure-path tests for installer/setup_helper.ps1, focused on migrating from the
# script install. Run unelevated on Windows:
#   powershell -ExecutionPolicy Bypass -File installer\tests\test_setup_helper.ps1
# Task Scheduler, Event Log and icacls are mocked, so the real guard task is never
# touched. Processes are real dummies (python sleeping at fake script-install paths,
# a copy of ping.exe as the new guard) under %TEMP%\12vg-migtest; shortcut folders
# are test folders too. -Helper runs the tests against another setup_helper.ps1.
param([string]$Helper)
$ErrorActionPreference = "Stop"
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Refusing to run elevated" }

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$py = Join-Path (Split-Path -Parent (& py -3 -c "import sys; print(sys.executable)")) "pythonw.exe"
if (!(Test-Path $py)) { throw "pythonw.exe not found (needs the py launcher)" }
$t = Join-Path $env:TEMP "12vg-migtest"
if (Test-Path $t) { Remove-Item $t -Recurse -Force }
$helperDir = Join-Path $t "helper"; New-Item -ItemType Directory -Force $helperDir | Out-Null
if (-not $Helper) { $Helper = "$repo\installer\setup_helper.ps1" }
Copy-Item $Helper "$helperDir\setup_helper.ps1"; Copy-Item "$repo\guard\guard_task.ps1" $helperDir
$inst = Join-Path $t "Program Files\12VHPWR Guard"; $data = Join-Path $t "ProgramData\12VHPWR Guard"
$newExe = Join-Path $inst "guard\12VHPWR-Guard.exe"

# Fake script install
$legacyGuard = Join-Path $t "legacy\guard"; $legacyOverlayDir = Join-Path $t "legacy\overlay"
New-Item -ItemType Directory -Force $legacyGuard, $legacyOverlayDir | Out-Null
$legacyScript = Join-Path $legacyGuard "hwinfo_12vhpwr_guard.py"
$legacyOverlay = Join-Path $legacyOverlayDir "overlay_app.py"
# Like the venv launcher: the real interpreter is a child without the script path.
"import subprocess, sys, time`nsubprocess.Popen([sys.executable, '-c', 'import time; time.sleep(600)'])`ntime.sleep(600)" | Set-Content $legacyScript
"import time; time.sleep(600)" | Set-Content $legacyOverlay
"[Settings]`nthreshold_amps = 9.5`nsustained_seconds_required = 15" | Set-Content "$legacyGuard\config.ini"
"{`"locked`": true}" | Set-Content "$legacyGuard\mitigation.active"
"{`"reason`": `"test`"}" | Set-Content "$legacyGuard\last_shutdown.json"
# Must never be touched: unrelated python, and a near-miss path (.py.bak).
$unrelatedScript = Join-Path $t "other\tool.py"; New-Item -ItemType Directory -Force (Split-Path $unrelatedScript) | Out-Null
"import time; time.sleep(600)" | Set-Content $unrelatedScript
Copy-Item $legacyScript "$legacyScript.bak"

# Shortcut folders
$scStartup = Join-Path $t "Startup"; $scPrograms = Join-Path $t "Programs"
New-Item -ItemType Directory -Force $scStartup, $scPrograms | Out-Null
$shell = New-Object -ComObject WScript.Shell
function New-Lnk($path, $target, $arguments) { $s = $shell.CreateShortcut($path); $s.TargetPath = $target; $s.Arguments = $arguments; $s.Save() }
New-Lnk "$scStartup\12VHPWR Guard Overlay.lnk" $py "`"$legacyOverlay`""
New-Lnk "$scPrograms\12VHPWR Guard Overlay.lnk" $py "`"$legacyOverlay`""
New-Lnk "$scStartup\Renamed old overlay.lnk" $py "`"$legacyOverlay`""
New-Lnk "$scStartup\Decoy bak.lnk" $py "`"$legacyOverlay.bak`""
New-Lnk "$scStartup\Other python tool.lnk" $py "`"$unrelatedScript`""
New-Lnk "$scPrograms\New overlay.lnk" (Join-Path $inst "overlay\12VHPWR-Guard-Overlay.exe") ""
# Regression: a shortcut with no TargetPath (like the shell's "File Explorer.lnk") and
# an unreadable one aborted the scan; this old-overlay shortcut sorts after them.
$emptyTarget = [byte[]](@(0x4C,0,0,0, 0x01,0x14,0x02,0,0,0,0,0,0xC0,0,0,0,0,0,0,0x46) + @(0) * 56 + @(0,0,0,0))
$emptyTarget[60] = 1   # ShowCommand = SW_SHOWNORMAL; no target ID list, no link info
[IO.File]::WriteAllBytes("$scPrograms\File Explorer.lnk", $emptyTarget)
[IO.File]::WriteAllBytes("$scPrograms\Broken.lnk", [byte[]](1..40))
New-Lnk "$scPrograms\Zz old overlay.lnk" $py "`"$legacyOverlay`""
if ($shell.CreateShortcut("$scPrograms\File Explorer.lnk").TargetPath) { throw "test shortcut should have an empty target" }
function Remove-Retry($path) { for ($i = 0; $i -lt 20; $i++) { try { Remove-Item $path -Recurse -Force; return } catch { Start-Sleep -Milliseconds 250 } }; Remove-Item $path -Recurse -Force }

# ---- Mocks (module first: its commands are functions that would overwrite mocks)
Import-Module ScheduledTasks
$global:calls = New-Object System.Collections.ArrayList
$global:task = $null; $global:taskProc = $null
$global:startMode = "ok"; $global:failRegister = $false
function global:Get-ScheduledTask { param($TaskName)
    if (-not $global:task) { return $null }
    $state = if ($global:taskProc -and -not $global:taskProc.HasExited) { "Running" } else { "Ready" }
    [pscustomobject]@{ State = $state; Actions = @([pscustomobject]@{ Execute = $global:task.Execute; Arguments = $global:task.Arguments }) } }
function global:Start-ScheduledTask { param($TaskName)
    [void]$global:calls.Add("Start")
    if (-not $global:task) { throw "task missing" }
    if ($global:task.Execute -eq $newExe) {
        $a = if ($global:startMode -eq "ok") { "-n 600 127.0.0.1" } else { "-n 1 127.0.0.1" }
        $global:taskProc = Start-Process $newExe -ArgumentList $a -WindowStyle Hidden -PassThru
    } else {
        $global:taskProc = Start-Process $global:task.Execute -ArgumentList $global:task.Arguments -PassThru
    } }
# Ends only the task's own process (the launcher), like Task Scheduler.
function global:Stop-ScheduledTask { param($TaskName) [void]$global:calls.Add("Stop")
    if ($global:taskProc -and -not $global:taskProc.HasExited) { Stop-Process -Id $global:taskProc.Id -Force } }
function global:Unregister-ScheduledTask { [void]$global:calls.Add("Unregister"); $global:task = $null }
function global:Register-ScheduledTask { param($TaskName, $Action, $Trigger, $Principal, $Settings, $Xml, [switch]$Force)
    if ($global:failRegister) { throw "Simulated registration failure" }
    if ($Xml) { $x = [xml]$Xml; $global:task = [pscustomobject]@{ Execute = $x.Task.Actions.Exec.Command; Arguments = $x.Task.Actions.Exec.Arguments }; [void]$global:calls.Add("RegisterXml") }
    else { $global:task = [pscustomobject]@{ Execute = $Action.Execute; Arguments = $Action.Arguments }; [void]$global:calls.Add("Register") } }
function global:Export-ScheduledTask { param($TaskName)
    $e = [Security.SecurityElement]::Escape($global:task.Execute); $a = [Security.SecurityElement]::Escape("$($global:task.Arguments)")
    "<?xml version=`"1.0`" encoding=`"UTF-16`"?>`n<Task xmlns=`"http://schemas.microsoft.com/windows/2004/02/mit/task`"><Actions><Exec><Command>$e</Command><Arguments>$a</Arguments></Exec></Actions></Task>" }
function global:New-EventLog { }
function global:Remove-EventLog { [void]$global:calls.Add("Remove-EventLog") }
function global:icacls.exe { $global:LASTEXITCODE = 0 }

function Run($action, [switch]$ExpectFail) {
    $global:calls.Clear()
    & "$helperDir\setup_helper.ps1" -Action $action -InstallDir $inst -DataDir $data -LogFile "$data\setup.log" `
        -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -ShortcutDirs @($scStartup, $scPrograms) `
        -StartTimeoutSec 8 -StableSec 2 | Out-Null
    $code = $LASTEXITCODE
    if (($code -eq 0) -eq [bool]$ExpectFail) {
        throw "$action exit code $code (ExpectFail=$ExpectFail). Log tail:`n$((Get-Content "$data\setup.log" -Tail 4) -join "`n")" }
    "{0,-10} exit {1}  [{2}]" -f $action, $code, ($global:calls -join ",")
}
function Check($cond, $msg) { if (-not $cond) { throw "FAIL: $msg" }; "    ok: $msg" }
function Alive($id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
function ByScript($path) { @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.Contains("`"$path`"") }) }
function Start-Legacy {
    $global:task = [pscustomobject]@{ Execute = $py; Arguments = "`"$legacyScript`"" }
    Start-ScheduledTask -TaskName x
    Start-Sleep -Seconds 2
    $script:launcher = $global:taskProc.Id
    $script:child = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$launcher").ProcessId
    if (-not $script:child) { throw "legacy child did not start" }
}
function GuardExes { @(Get-Process -Name 12VHPWR-Guard -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $newExe }) }

# Python processes that existed before the test must all survive it.
$preexisting = @(Get-Process -Name python, pythonw -ErrorAction SilentlyContinue | ForEach-Object Id)
$realTaskBefore = (ScheduledTasks\Get-ScheduledTask -TaskName "12VHPWR Guard" -ErrorAction SilentlyContinue).State

$bystanders = @(
    (Start-Process $py -ArgumentList "`"$unrelatedScript`"" -PassThru).Id,
    (Start-Process $py -ArgumentList "`"$legacyScript.bak`"" -PassThru).Id)
$oldOverlay = (Start-Process $py -ArgumentList "`"$legacyOverlay`"" -PassThru).Id
New-Item -ItemType Directory -Force (Split-Path $newExe), (Join-Path $inst "overlay") | Out-Null

try {
    "== 1. Script install -> registration fails after the old task was deleted -> rollback"
    Start-Legacy
    Run Prepare
    Check (-not (Alive $launcher) -and -not (Alive $child)) "old launcher AND its child interpreter exited"
    Check ((Alive $bystanders[0]) -and (Alive $bystanders[1])) "unrelated python and .py.bak near-miss untouched"
    Check (Alive $oldOverlay) "old overlay left running until install succeeds"
    Check ((Get-Content "$data\config.ini" -Raw) -match "sustained_seconds_required = 15") "config imported (15 s)"
    Check ((Test-Path "$data\mitigation.active") -and (Test-Path "$data\last_shutdown.json")) "mitigation + last_shutdown state imported"
    Check ((Test-Path "$legacyGuard\mitigation.active")) "state still in script install for rollback"
    Check (Test-Path "$data\backup\task.xml") "task XML backed up"
    Copy-Item "$env:SystemRoot\System32\PING.EXE" $newExe   # setup copies new files
    $global:failRegister = $true
    Run Configure -ExpectFail
    $global:failRegister = $false
    Check (-not $global:task) "old task really deleted by the failed registration"
    Run Restore
    Check ($global:task.Execute -eq $py -and $global:task.Arguments -eq "`"$legacyScript`"") "old task re-registered from backup"
    Check ($global:taskProc -and -not $global:taskProc.HasExited) "old guard running again"
    Check (Test-Path "$scStartup\12VHPWR Guard Overlay.lnk") "old shortcuts untouched on rollback"

    "== 2. New guard crashes on start -> failure reported -> rollback"
    Run Prepare
    $global:startMode = "crash"
    Run Configure -ExpectFail
    Check ((Get-Content "$data\setup.log" -Tail 1) -match "did not keep running") "startup failure reported"
    $global:startMode = "ok"
    Run Restore
    Check ($global:task.Execute -eq $py -and -not $global:taskProc.HasExited) "old guard restored and running"
    Check ((GuardExes).Count -eq 0) "no new guard left behind"

    "== 3. A second new guard instance -> 'exactly one' check fails -> rollback"
    Run Prepare
    $extra = Start-Process $newExe -ArgumentList "-n 600 127.0.0.1" -WindowStyle Hidden -PassThru
    Run Configure -ExpectFail
    Run Restore
    Check (-not (Alive $extra.Id) -and (GuardExes).Count -eq 0) "duplicate instances stopped during rollback"
    Check ($global:task.Execute -eq $py -and -not $global:taskProc.HasExited) "old guard restored and running"

    "== 4. Successful migration"
    $launcher = $global:taskProc.Id
    $child = (Get-CimInstance Win32_Process -Filter "ParentProcessId=$launcher").ProcessId
    Run Prepare
    Check (-not (Alive $launcher) -and -not (Alive $child)) "old guard tree exited"
    Run Configure
    Check ((GuardExes).Count -eq 1 -and $global:task.Execute -eq $newExe) "exactly one new guard running from the new task"
    Run Cleanup
    Check (-not (Alive $oldOverlay)) "old overlay stopped"
    Check (-not (Test-Path "$scStartup\12VHPWR Guard Overlay.lnk") -and -not (Test-Path "$scPrograms\12VHPWR Guard Overlay.lnk") -and -not (Test-Path "$scStartup\Renamed old overlay.lnk")) "old overlay shortcuts removed (matched by target)"
    Check ((Test-Path "$scStartup\Decoy bak.lnk") -and (Test-Path "$scStartup\Other python tool.lnk") -and (Test-Path "$scPrograms\New overlay.lnk")) "unrelated shortcuts kept"
    Check (-not (Test-Path "$scPrograms\Zz old overlay.lnk")) "scan continued past empty-target and unreadable shortcuts"
    Check ((Test-Path "$scPrograms\File Explorer.lnk") -and (Test-Path "$scPrograms\Broken.lnk")) "empty-target and unreadable shortcuts kept"
    Check (-not (Test-Path "$data\backup")) "backup removed"
    Check ((Alive $bystanders[0]) -and (Alive $bystanders[1])) "unrelated python still untouched"

    "== 4b. Same-version in-place reinstall over the installed build"
    "[Settings]`nthreshold_amps = 9.0`nsustained_seconds_required = 15" | Set-Content "$data\config.ini"
    "{`"locked`": true}" | Set-Content "$data\mitigation.active"
    $cfgHash = (Get-FileHash "$data\config.ini").Hash
    $overlayExe = Join-Path $inst "overlay\12VHPWR-Guard-Overlay.exe"
    Copy-Item "$env:SystemRoot\System32\PING.EXE" $overlayExe
    $ov = Start-Process $overlayExe -ArgumentList "-n 600 127.0.0.1" -WindowStyle Hidden -PassThru
    $oldGuard = $global:taskProc.Id
    Run Prepare
    Check (-not (Alive $oldGuard) -and -not (Alive $ov.Id)) "running guard and overlay stopped"
    Check (-not (Test-Path "$data\backup\legacy.json")) "not mistaken for a script install"
    Check ((Test-Path "$data\backup\complete") -and (Test-Path "$data\backup\task.xml")) "binaries and task backed up"
    # What Inno does next: [InstallDelete] the PyInstaller folders, copy the new build.
    Remove-Retry "$inst\guard"; Remove-Retry "$inst\overlay"
    New-Item -ItemType Directory -Force (Split-Path $newExe), (Split-Path $overlayExe) | Out-Null
    Copy-Item "$env:SystemRoot\System32\PING.EXE" $newExe; Copy-Item "$env:SystemRoot\System32\PING.EXE" $overlayExe
    Run Configure
    Check ((GuardExes).Count -eq 1 -and $global:task.Execute -eq $newExe -and $global:taskProc.Id -ne $oldGuard) "restarted as exactly one new guard"
    Run Cleanup
    Check ((Get-FileHash "$data\config.ini").Hash -eq $cfgHash) "config preserved byte-for-byte"
    Check (Test-Path "$data\mitigation.active") "mitigation recovery state preserved"
    Check (-not (Test-Path "$data\backup")) "backup removed"
    Remove-Item "$data\mitigation.active"

    "== 5. Upgrade of the installed version fails -> files and task restored"
    Run Prepare
    Check (Test-Path "$data\backup\complete") "binaries backed up"
    "new" | Set-Content "$inst\guard\only-in-v2.dll"
    $global:failRegister = $true; Run Configure -ExpectFail; $global:failRegister = $false
    Run Restore
    Check (-not (Test-Path "$inst\guard\only-in-v2.dll")) "binaries rolled back"
    Check ($global:task.Execute -eq $newExe -and (GuardExes).Count -eq 1) "installed guard task restored and running"

    "== 6. Incomplete binary backup is never restored"
    Run Prepare
    Remove-Item "$data\backup\complete"
    "v3" | Set-Content "$inst\guard\marker-v3.txt"
    Run Restore
    Check (Test-Path "$inst\guard\marker-v3.txt") "partial backup ignored"
    Check ((GuardExes).Count -eq 1) "guard running"

    "== 7. Fresh install (no previous task) fails -> nothing to restore"
    Stop-ScheduledTask -TaskName x; [void]$global:taskProc.WaitForExit(5000); $global:task = $null
    Remove-Item $inst -Recurse -Force
    Run Prepare
    New-Item -ItemType Directory -Force (Split-Path $newExe) | Out-Null; Copy-Item "$env:SystemRoot\System32\PING.EXE" $newExe
    $global:startMode = "crash"; Run Configure -ExpectFail; $global:startMode = "ok"
    Run Restore
    Check ((Get-Content "$data\setup.log" -Tail 1) -match "Nothing to restore") "reported, no-op"

    "== 8. Uninstall"
    $global:startMode = "ok"; Run Configure
    Run Uninstall
    Check (-not $global:task -and (GuardExes).Count -eq 0) "task removed, guard stopped"
    Check ((Get-Content "$data\config.ini" -Raw) -match "15") "config kept"
    "ALL PASSED"
} finally {
    # Remove only processes this test started: those under $t and their descendants.
    $all = @(Get-CimInstance Win32_Process); $kill = @{}
    foreach ($p in $all) { if (($p.CommandLine -and $p.CommandLine.Contains($t)) -or ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($t))) { $kill[[int]$p.ProcessId] = $p } }
    do { $added = $false; foreach ($p in $all) { $par = $kill[[int]$p.ParentProcessId]; if (-not $kill.ContainsKey([int]$p.ProcessId) -and $par -and $p.CreationDate -ge $par.CreationDate) { $kill[[int]$p.ProcessId] = $p; $added = $true } } } while ($added)
    $kill.Keys | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
    "cleaned up $($kill.Count) test processes"
    $realTaskAfter = (ScheduledTasks\Get-ScheduledTask -TaskName "12VHPWR Guard" -ErrorAction SilentlyContinue).State
    "real '12VHPWR Guard' task: before=$realTaskBefore after=$realTaskAfter"
    $gone = @($preexisting | Where-Object { -not (Alive $_) })
    "pre-existing python processes: $($preexisting.Count), gone: $($gone.Count)"
}



