"""
File locations shared with the guard, plus the overlay's own per-user files.

Mirrors guard/app_paths.py (not imported: the overlay never imports guard code).
Source checkout: status.json / pending_settings.json at the project root, config in
guard/config.ini, UI state next to this file - unchanged from before. Installed build
(PyInstaller, sys.frozen): shared files under %ProgramData%\\12VHPWR Guard, with the
request file in its user-writable requests\\ subfolder, and UI state per user under
%LOCALAPPDATA%\\12VHPWR Guard.
"""

import ctypes
import os
import sys

APP_DIR_NAME = "12VHPWR Guard"
FROZEN = bool(getattr(sys, "frozen", False))
CSIDL_COMMON_APPDATA = 0x0023


def _program_data_dir() -> str:
    try:
        buf = ctypes.create_unicode_buffer(260)
        if ctypes.windll.shell32.SHGetFolderPathW(None, CSIDL_COMMON_APPDATA, None, 0, buf) == 0:
            return buf.value
    except Exception:
        pass
    return r"C:\ProgramData"


_OVERLAY_DIR = os.path.dirname(os.path.abspath(__file__))

if FROZEN:
    _DATA_DIR = os.path.join(_program_data_dir(), APP_DIR_NAME)
    SHARED_DIR = _DATA_DIR
    REQUESTS_DIR = os.path.join(_DATA_DIR, "requests")
    GUARD_CONFIG_PATH = os.path.join(_DATA_DIR, "config.ini")
    USER_DIR = os.path.join(
        os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), APP_DIR_NAME
    )
else:
    SHARED_DIR = os.path.dirname(_OVERLAY_DIR)  # project root
    REQUESTS_DIR = SHARED_DIR
    GUARD_CONFIG_PATH = os.path.join(SHARED_DIR, "guard", "config.ini")
    USER_DIR = _OVERLAY_DIR

STATUS_PATH = os.path.join(SHARED_DIR, "status.json")
POSITION_FILE = os.path.join(USER_DIR, "overlay_position.json")
# Optional personal window icon; never shipped with the project or the installer.
ICON_FILE = os.path.join(USER_DIR, "astral_guard.ico")
# Project icon, shipped with the overlay; used when there is no personal icon.
# PyInstaller unpacks bundled data under sys._MEIPASS.
DEFAULT_ICON_FILE = os.path.join(getattr(sys, "_MEIPASS", _OVERLAY_DIR), "astral_guard_public.ico")
