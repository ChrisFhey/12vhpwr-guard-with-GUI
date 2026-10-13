# PyInstaller spec for the elevated guard. Build with installer/build.ps1.
import os

ROOT = os.path.abspath(os.path.join(SPECPATH, ".."))
GUARD = os.path.join(ROOT, "guard")

# The guard imports these inside try/except and quietly degrades (e.g. to
# shutdown-only) when one is missing, so list them explicitly; build.ps1 also
# checks they made it into the archive.
GUARD_MODULES = [
    "app_paths", "astral_i2c", "gpu_mitigation", "telemetry",
    "hwinfo_voltage", "status_writer", "settings_bridge",
]

a = Analysis(
    [os.path.join(GUARD, "hwinfo_12vhpwr_guard.py")],
    pathex=[GUARD],
    hiddenimports=GUARD_MODULES + ["pystray._win32", "win32evtlogutil", "win32con"],
    excludes=["pystray._xorg", "pystray._gtk", "pystray._appindicator", "pystray._darwin"],
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="12VHPWR-Guard",
    console=False,
    upx=False,
    icon="NONE",
    version=os.environ.get("GUARD_VERSION_FILE"),
)
coll = COLLECT(exe, a.binaries, a.datas, name="12VHPWR-Guard", upx=False)
