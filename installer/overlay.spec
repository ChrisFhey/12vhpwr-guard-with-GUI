# PyInstaller spec for the unprivileged overlay. Build with installer/build.ps1.
# Ships only the public project icon; a personal astral_guard.ico is never bundled.
import os

ROOT = os.path.abspath(os.path.join(SPECPATH, ".."))
OVERLAY = os.path.join(ROOT, "overlay")
APP_ICON = os.path.join(OVERLAY, "astral_guard_public.ico")

a = Analysis(
    [os.path.join(OVERLAY, "overlay_app.py")],
    pathex=[OVERLAY],
    datas=[(APP_ICON, ".")],
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
    icon=APP_ICON,
    version=os.environ.get("OVERLAY_VERSION_FILE"),
)
coll = COLLECT(exe, a.binaries, a.datas, name="12VHPWR-Guard-Overlay", upx=False)
