"""
Where the guard keeps its writable files.

Source checkout (`python hwinfo_12vhpwr_guard.py`): unchanged from before - config,
logs and state next to the scripts, status.json / pending_settings.json at the
project root where the overlay looks for them.

Installed build (PyInstaller, sys.frozen): binaries live under Program Files, which
is replaced on every upgrade, so writable data goes to %ProgramData%\\12VHPWR Guard
instead. The overlay's request file gets its own subfolder because it is the only
location the installer makes writable for unprivileged users.

The ProgramData path is resolved through the shell API rather than the ProgramData
environment variable: this module runs inside the elevated guard, and a per-user
environment variable must not be able to redirect where it reads its config.
"""

import ctypes
import os
import sys

APP_DIR_NAME = "12VHPWR Guard"
FROZEN = bool(getattr(sys, "frozen", False))
CSIDL_COMMON_APPDATA = 0x0023


def program_data_dir() -> str:
    try:
        buf = ctypes.create_unicode_buffer(260)
        if ctypes.windll.shell32.SHGetFolderPathW(None, CSIDL_COMMON_APPDATA, None, 0, buf) == 0:
            return buf.value
    except Exception:
        pass
    return r"C:\ProgramData"


_SOURCE_DIR = os.path.dirname(os.path.abspath(__file__))

if FROZEN:
    DATA_DIR = os.path.join(program_data_dir(), APP_DIR_NAME)
    SHARED_DIR = DATA_DIR
    REQUESTS_DIR = os.path.join(DATA_DIR, "requests")
else:
    DATA_DIR = _SOURCE_DIR
    SHARED_DIR = os.path.dirname(_SOURCE_DIR)
    REQUESTS_DIR = SHARED_DIR
