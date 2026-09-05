"""
Consumes threshold/sustained-seconds change requests written by the overlay process.

The overlay runs unprivileged and cannot call into the guard's in-process globals
directly, so it drops a small request file instead. This module is polled once per
monitor_loop tick and, if a request is present, applies it through the exact same
set_config_values() + save_config() pair the tray menu's change_threshold_amps() /
change_sustained_seconds() callbacks already use - so a change made from the overlay
behaves identically to one made from the tray: live, no restart, persisted to
config.ini.

The overlay is responsible for its own "raising above default reduces protection"
confirmation before ever writing this file (mirroring the tray's confirm_unsafe_value
dialog) - this module applies whatever it is asked to apply, unconditionally, because
enforcing that confirmation from the elevated side would need to know how the request
UI made its decision. It is not this module's job to re-implement that dialog.
"""

import json
import os
from typing import Optional

PENDING_FILENAME = "pending_settings.json"


def pending_path(base_dir: str) -> str:
    return os.path.join(base_dir, PENDING_FILENAME)


def consume_pending_settings(base_dir: str, logger=None) -> Optional[dict]:
    """Reads and deletes the request file if present, applying it via the caller-
    supplied setters. Returns the applied dict, or None if there was nothing to do
    or the request was malformed (a malformed request is discarded, not retried
    forever)."""
    path = pending_path(base_dir)
    if not os.path.exists(path):
        return None

    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as ex:
        if logger:
            logger.warning(f"Discarding unreadable pending_settings.json ({ex})")
        _remove(path)
        return None

    _remove(path)

    if not isinstance(data, dict):
        return None

    threshold = data.get("threshold_amps")
    sustained = data.get("sustained_seconds_required")
    if threshold is None and sustained is None:
        return None

    try:
        threshold = float(threshold) if threshold is not None else None
        sustained = float(sustained) if sustained is not None else None
    except (TypeError, ValueError):
        if logger:
            logger.warning(f"Discarding pending_settings.json with non-numeric values: {data}")
        return None

    if (threshold is not None and threshold <= 0) or (sustained is not None and sustained <= 0):
        if logger:
            logger.warning(f"Discarding pending_settings.json with non-positive values: {data}")
        return None

    return {"threshold_amps": threshold, "sustained_seconds_required": sustained}


def _remove(path: str) -> None:
    try:
        os.remove(path)
    except Exception:
        pass
