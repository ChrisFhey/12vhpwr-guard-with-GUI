"""
Settings popup for the overlay: edits threshold_amps / sustained_seconds_required.

Writes a pending_settings.json request that the guard's monitor_loop consumes and
applies through its own set_config_values()/save_config() (see guard/settings_bridge.py
and the corresponding hook in guard/hwinfo_12vhpwr_guard.py). This module never
touches config.ini directly and never talks to the GPU - it only ever writes one
small JSON request file.

Mirrors the tray menu's confirm_unsafe_value() safety check: raising a value above its
documented default weakens protection, and the upstream project always confirms that
before accepting it. Since the overlay is a separate process from the tray, that
confirmation has to be re-implemented here rather than reused - dropping it silently
because the UI moved to a new process would be a regression, not a simplification.
"""

import json
import os
import time
import tkinter as tk
from tkinter import messagebox
from typing import Optional

# Mirrors guard/hwinfo_12vhpwr_guard.py's DEFAULT_THRESHOLD_AMPS /
# DEFAULT_SUSTAINED_SECONDS_REQUIRED. Kept as plain constants here (not imported)
# because the overlay process must not import the guard's module - that module has
# side effects on import (reads config.ini, binds optional hardware modules) that
# belong only to the elevated guard process.
DEFAULT_THRESHOLD_AMPS = 9.5
DEFAULT_SUSTAINED_SECONDS_REQUIRED = 10.0

PENDING_FILENAME = "pending_settings.json"
CONFIG_FILENAME = os.path.join("guard", "config.ini")


def _read_current_values(base_dir: str):
    """Best-effort read of the guard's config.ini for display only (never written
    to directly - see module docstring). Falls back to defaults if unreadable."""
    import configparser
    path = os.path.join(base_dir, CONFIG_FILENAME)
    threshold = DEFAULT_THRESHOLD_AMPS
    sustained = DEFAULT_SUSTAINED_SECONDS_REQUIRED
    try:
        cfg = configparser.ConfigParser()
        cfg.read(path, encoding="utf-8")
        threshold = cfg.getfloat("Settings", "threshold_amps", fallback=threshold)
        sustained = cfg.getfloat("Settings", "sustained_seconds_required", fallback=sustained)
    except Exception:
        pass
    return threshold, sustained


def _write_pending(base_dir: str, threshold: Optional[float], sustained: Optional[float]) -> None:
    path = os.path.join(base_dir, PENDING_FILENAME)
    tmp = path + ".tmp"
    payload = {}
    if threshold is not None:
        payload["threshold_amps"] = threshold
    if sustained is not None:
        payload["sustained_seconds_required"] = sustained
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


class SettingsPopup:
    def __init__(self, parent: tk.Tk, base_dir: str, overlay_app=None):
        """overlay_app: the OverlayApp instance, used only for the live size slider
        (calls overlay_app.set_scale()). Optional so this module stays testable/usable
        without a live overlay window if ever needed - the threshold/sustained fields
        never depended on it."""
        self.base_dir = base_dir
        self.overlay_app = overlay_app
        self.window = tk.Toplevel(parent)
        self.window.title("12VHPWR Guard Settings")
        self.window.attributes("-topmost", True)
        self.window.resizable(False, False)
        self.window.configure(padx=16, pady=14)

        current_threshold, current_sustained = _read_current_values(base_dir)

        tk.Label(self.window, text="Overcurrent threshold (A):").grid(row=0, column=0, sticky="w")
        self.threshold_var = tk.StringVar(value=f"{current_threshold:.2f}")
        tk.Entry(self.window, textvariable=self.threshold_var, width=10).grid(row=0, column=1, padx=(8, 0))

        tk.Label(self.window, text="Sustained duration (s):").grid(row=1, column=0, sticky="w", pady=(8, 0))
        self.sustained_var = tk.StringVar(value=f"{current_sustained:.1f}")
        tk.Entry(self.window, textvariable=self.sustained_var, width=10).grid(row=1, column=1, padx=(8, 0), pady=(8, 0))

        note = (f"Defaults: {DEFAULT_THRESHOLD_AMPS:.1f} A / "
                f"{DEFAULT_SUSTAINED_SECONDS_REQUIRED:.0f} s. Raising either value "
                f"reduces protection.")
        tk.Label(self.window, text=note, fg="#888888", wraplength=260,
                 justify="left", font=("Segoe UI", 8)).grid(
            row=2, column=0, columnspan=2, sticky="w", pady=(10, 10))

        next_row = 3
        if self.overlay_app is not None:
            tk.Label(self.window, text="Overlay size:").grid(row=next_row, column=0, sticky="w")
            from overlay_app import MIN_SCALE, MAX_SCALE
            self.scale_var = tk.DoubleVar(value=self.overlay_app.scale)
            scale_slider = tk.Scale(
                self.window, from_=MIN_SCALE, to=MAX_SCALE, resolution=0.1,
                orient="horizontal", variable=self.scale_var, length=160,
                showvalue=True, command=self._on_scale_change,
            )
            scale_slider.grid(row=next_row, column=1, padx=(8, 0), sticky="w")
            next_row += 1

            tk.Label(self.window, text="Show readings:", fg="#888888",
                     font=("Segoe UI", 8)).grid(
                row=next_row, column=0, columnspan=2, sticky="w", pady=(10, 2))
            next_row += 1

            from overlay_app import STAT_FIELDS
            self.stat_vars = {}
            checks_frame = tk.Frame(self.window)
            checks_frame.grid(row=next_row, column=0, columnspan=2, sticky="w")
            for i, (key, caption) in enumerate(STAT_FIELDS):
                var = tk.BooleanVar(value=self.overlay_app.visible_stats.get(key, True))
                self.stat_vars[key] = var
                cb = tk.Checkbutton(
                    checks_frame, text=caption, variable=var,
                    command=lambda k=key, v=var: self._on_visibility_change(k, v),
                )
                cb.grid(row=i // 2, column=i % 2, sticky="w", padx=(0, 10))
            next_row += 1

        button_row = tk.Frame(self.window)
        button_row.grid(row=next_row, column=0, columnspan=2, sticky="e", pady=(10, 0))
        tk.Button(button_row, text="Cancel", command=self.window.destroy).pack(side="right", padx=(6, 0))
        tk.Button(button_row, text="Apply", command=self._on_apply).pack(side="right")

        self.window.protocol("WM_DELETE_WINDOW", self.window.destroy)

    def _on_visibility_change(self, key: str, var: tk.BooleanVar) -> None:
        """Live, immediate - like the size slider, visibility carries no safety
        implications, so there's no reason to gate it behind Apply."""
        if self.overlay_app is not None:
            self.overlay_app.set_stat_visible(key, var.get())

    def _on_scale_change(self, value) -> None:
        """Live preview: resizes the overlay immediately as the slider moves, so the
        user sees the effect before clicking Apply (which only concerns the safety
        values - size takes effect immediately since it carries no risk)."""
        if self.overlay_app is not None:
            self.overlay_app.set_scale(float(value))

    def is_open(self) -> bool:
        return bool(self.window.winfo_exists())

    def focus(self) -> None:
        self.window.lift()
        self.window.focus_force()

    def _on_apply(self) -> None:
        try:
            new_threshold = float(self.threshold_var.get())
            new_sustained = float(self.sustained_var.get())
        except ValueError:
            messagebox.showerror("Invalid value", "Threshold and duration must be numbers.",
                                  parent=self.window)
            return

        if new_threshold <= 0 or new_sustained <= 0:
            messagebox.showerror("Invalid value", "Values must be greater than zero.",
                                  parent=self.window)
            return

        if not self._confirm_if_unsafe("threshold", new_threshold, DEFAULT_THRESHOLD_AMPS, "A"):
            return
        if not self._confirm_if_unsafe("sustained duration", new_sustained,
                                        DEFAULT_SUSTAINED_SECONDS_REQUIRED, "s"):
            return

        try:
            _write_pending(self.base_dir, new_threshold, new_sustained)
        except Exception as ex:
            messagebox.showerror("Could not apply", f"Failed to write settings request: {ex}",
                                  parent=self.window)
            return

        self.window.destroy()

    def _confirm_if_unsafe(self, kind: str, new_value: float, default_value: float,
                            unit: str) -> bool:
        """Same rule as the tray's confirm_unsafe_value(): raising above default asks
        for confirmation, lowering or matching it does not."""
        if new_value <= default_value:
            return True
        return messagebox.askyesno(
            "Warning: Reduced Protection",
            f"Raising the {kind} above the default ({default_value:g} {unit}) reduces "
            f"protection and increases the risk of connector overheating, melting, or "
            f"fire.\n\nRequested: {new_value:g} {unit}\nDefault: {default_value:g} {unit}"
            f"\n\nApply anyway?",
            parent=self.window,
        )
