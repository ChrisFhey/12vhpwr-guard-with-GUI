# PyInstaller spec for the unprivileged overlay. Build with installer/build.ps1.
# No data files: the optional window icon is a per-user file and is never bundled.
import os

ROOT = os.path.abspath(os.path.join(SPECPATH, ".."))
OVERLAY = os.path.join(ROOT, "overlay")

a = Analysis(
    [os.path.join(OVERLAY, "overlay_app.py")],
    pathex=[OVERLAY],
    # overlay_settings imports overlay_app lazily for shared constants.
    hiddenimports=["overlay_app", "overlay_paths", "overlay_settings", "overlay_theme"],
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="12VHPWR-Guard-Overlay",
    console=False,
    upx=False,
    icon="NONE",
    version=os.environ.get("OVERLAY_VERSION_FILE"),
)
coll = COLLECT(exe, a.binaries, a.datas, name="12VHPWR-Guard-Overlay", upx=False)
