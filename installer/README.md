# Windows installer

Packages the guard and overlay as standalone executables (PyInstaller, no Python
needed on the target) inside an Inno Setup installer that handles install, upgrade
and uninstall.

## Build

Requirements on the build machine: Windows x64, Python 3.10+ (`py` launcher), and
[Inno Setup 6.3+](https://jrsoftware.org/isinfo.php).

```powershell
powershell -ExecutionPolicy Bypass -File installer\build.ps1
```

Output: `installer\Output\12VHPWR-Guard-Setup-<version>.exe`. Useful options:

- `-BuildDir C:\build\12vhpwr` - put the venv and PyInstaller output on a local disk
  (recommended when the repo lives on a WSL/network share).
- `-SkipInstaller` - build and verify the executables only.
- `-Version 1.4.0` - override the `VERSION` file.

The build fails if a guard protection module (`gpu_mitigation`, `astral_i2c`, ...)
is missing from the bundle, or if any `.ico` file ends up in it.

## What the installer does

| | Location / mechanism |
|---|---|
| Binaries | `C:\Program Files\12VHPWR Guard\{guard,overlay}\` |
| Config, logs, `status.json`, crash-recovery marker | `C:\ProgramData\12VHPWR Guard\` (admins write, users read) |
| Overlay settings requests | `...\ProgramData\12VHPWR Guard\requests\` (users may write) |
| Overlay window position | `%LOCALAPPDATA%\12VHPWR Guard\` |
| Guard | Task Scheduler `12VHPWR Guard`: at logon, highest privileges, same settings as `guard\install.ps1` (shared via `guard\guard_task.ps1`) |
| Overlay | All-users Startup shortcut (optional task) and Start Menu shortcut, runs unelevated |

Upgrades: setup stops the guard and overlays, backs up the current binaries to
`ProgramData\12VHPWR Guard\backup`, replaces the files, re-registers and starts the
task. If configuration fails or setup is cancelled after the guard was stopped, the
backup is restored and the previous guard restarted. Config and logs are never
touched. Details are logged to `ProgramData\12VHPWR Guard\setup.log`.

Uninstall removes the task, Event Log source, shortcuts and binaries; settings and
logs are kept unless you choose to delete them.

Silent install/upgrade: `12VHPWR-Guard-Setup-<version>.exe /VERYSILENT`. The guard
task runs as the logged-on console user; override with `/GuardUser=DOMAIN\name`.

The guard must run under an administrator account (as with the script install) so
it can write its data folder and apply GPU mitigation.

## Migrating from the script install

The installer replaces the `12VHPWR Guard` task and imports `guard\config.ini` from
the old location if no installed config exists yet. Afterwards run
`overlay\overlay_uninstaller.bat` from the old checkout to remove its per-user overlay
shortcuts, otherwise the old overlay also starts at logon.

## Releasing a new version

1. Merge upstream guard changes into `guard/`, keeping this fork's hooks
   (`app_paths`, `status_writer`, `settings_bridge`, `telemetry`, `hwinfo_voltage`).
2. Bump `VERSION` (numeric, e.g. `1.3.2` or `1.3.1.1`).
3. Build, then run the new setup over the existing install to upgrade.
