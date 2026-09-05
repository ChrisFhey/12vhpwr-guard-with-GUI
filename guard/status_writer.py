"""
Atomic JSON status snapshot for the overlay process.

Written once per monitor_loop poll tick (~0.5s) by the elevated guard, read by the
unprivileged overlay. This is a one-way, read-only channel from the guard's point of
view: nothing here feeds back into the threshold/shutdown decision, and a write
failure must never interrupt the monitor loop (matches the existing try/except style
used for last_shutdown.json / mitigation.active).

Atomic write (tmp file + os.replace) so the overlay never reads a half-written file -
the same durability pattern already used elsewhere in this codebase.
"""

import json
import os
import time
from typing import List, Optional, Tuple

STATUS_FILENAME = "status.json"
SCHEMA_VERSION = 1


def status_path(base_dir: str) -> str:
    return os.path.join(base_dir, STATUS_FILENAME)


def write_status(
    base_dir: str,
    *,
    guard_status: str,
    last_message: str,
    pins: List[Tuple[str, float, str]],
    pin_voltages: Optional[List[float]],
    threshold_amps: float,
    sustained_seconds_required: float,
    over_since: Optional[float],
    source: str,
    mitigation_engaged: bool,
    mitigation_state: str,
    telemetry: Optional[dict] = None,
) -> None:
    """Best-effort atomic write. Never raises - a failure here must not affect
    monitoring or shutdown, so every error is swallowed after being given a chance
    to reach the caller's logger by the caller, not here."""
    now = time.time()
    payload = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": now,
        "guard_status": guard_status,
        "last_message": last_message,
        "pins": [
            {"label": label, "amps": round(amps, 3), "unit": unit}
            for label, amps, unit in pins
        ],
        "pin_voltages": [round(v, 3) for v in pin_voltages] if pin_voltages else None,
        "threshold_amps": threshold_amps,
        "sustained_seconds_required": sustained_seconds_required,
        "seconds_over_threshold": (now - over_since) if over_since is not None else 0.0,
        "source": source,
        "mitigation_engaged": mitigation_engaged,
        "mitigation_state": mitigation_state,
        "telemetry": telemetry or {},
    }

    path = status_path(base_dir)
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        pass
