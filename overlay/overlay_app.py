"""
Overlay window showing live 12VHPWR per-pin current and GPU stats.

Uses native Windows decorations (title bar, taskbar entry, dark title bar where
supported), is not always-on-top, and has a fixed size. The window icon is the
shipped astral_guard_public.ico, or an optional personal astral_guard.ico (see
overlay_paths.ICON_FILE) when present.

Runs unprivileged, as a normal user process. Never touches NVAPI/NVML/I2C directly -
all data comes from status.json, written by the elevated guard process. This means a
bug here can never become a second, independently-wrong hardware reader: the overlay
is purely a renderer of whatever the guard already decided to report.

Stdlib only (tkinter + json + os + time): no extra install needed for the overlay
itself, matching the "super lightweight" requirement.
"""

import ctypes
import json
import os
import sys
import time
import tkinter as tk
from typing import Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from overlay_theme import bar_color, bar_fill_fraction
from overlay_settings import SettingsPopup, DEFAULT_THRESHOLD_AMPS, DEFAULT_SUSTAINED_SECONDS_REQUIRED
from overlay_paths import STATUS_PATH, POSITION_FILE, ICON_FILE, DEFAULT_ICON_FILE

POLL_INTERVAL_MS = 200          # overlay refresh rate (5 Hz is plenty for a bar chart)
STALE_AFTER_SEC = 2.0           # guard writes every ~0.5s; 2s of silence = disconnected
SINGLE_INSTANCE_MUTEX = r"Local\12VHPWR_Guard_Overlay_SingleInstance"
ERROR_ALREADY_EXISTS = 183

BG_COLOR = "#141414"
FG_COLOR = "#eaeaea"
DIM_COLOR = "#8a8a8a"
BAR_BG = "#2a2a2a"
BAR_WIDTH = 26
BAR_HEIGHT = 90
BAR_GAP = 10
WINDOW_ALPHA = 0.90

# Base font sizes at scale=1.0. Multiplied by the user's chosen scale factor in
# _build_ui(); Tkinter fonts want integer point sizes, so the result is rounded.
TITLE_FONT_SIZE = 10
LABEL_FONT_SIZE = 8
SMALL_FONT_SIZE = 7
ICON_FONT_SIZE = 11

MIN_SCALE = 0.6
MAX_SCALE = 2.5
DEFAULT_SCALE = 1.0

# (key, caption) for every optional stat row. Order here is display order. Whether
# each one is actually shown is controlled per-viewer by visible_stats (see
# load_ui_state / save_ui_state) and edited from the settings popup's checkboxes.
STAT_FIELDS = [
    ("power", "Power"),
    ("voltage", "12V Rail"),
    ("core_voltage", "Core V"),
    ("clock", "Clock"),
    ("vram", "VRAM"),
    ("gpu_util", "GPU"),
    ("temp", "Temp"),
]
DEFAULT_VISIBLE_STATS = {key: True for key, _ in STAT_FIELDS}


def read_status() -> Optional[dict]:
    """Best-effort read of the guard's snapshot. None if missing, stale, or corrupt -
    the caller must treat None as 'disconnected', never as 'zero'."""
    try:
        if not os.path.exists(STATUS_PATH):
            return None
        mtime = os.path.getmtime(STATUS_PATH)
        if (time.time() - mtime) > STALE_AFTER_SEC:
            return None
        with open(STATUS_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def load_ui_state():
    """Position, scale, and per-stat visibility, persisted locally per viewer - not
    shared with the guard or any other process, purely a UI convenience."""
    try:
        with open(POSITION_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        x = int(data.get("x", 40))
        y = int(data.get("y", 40))
        scale = float(data.get("scale", DEFAULT_SCALE))
        scale = max(MIN_SCALE, min(MAX_SCALE, scale))
        saved_visible = data.get("visible_stats", {})
        # Merge over the defaults rather than replacing outright, so a stat added in
        # a later version (like core_voltage here) defaults to shown for existing
        # users instead of silently vanishing because it's missing from their old
        # saved file.
        visible_stats = dict(DEFAULT_VISIBLE_STATS)
        if isinstance(saved_visible, dict):
            for key in visible_stats:
                if key in saved_visible:
                    visible_stats[key] = bool(saved_visible[key])
        return x, y, scale, visible_stats
    except Exception:
        return 40, 40, DEFAULT_SCALE, dict(DEFAULT_VISIBLE_STATS)


def save_ui_state(x: int, y: int, scale: float, visible_stats: dict) -> None:
    tmp = POSITION_FILE + ".tmp"
    try:
        os.makedirs(os.path.dirname(POSITION_FILE), exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"x": x, "y": y, "scale": scale, "visible_stats": visible_stats}, f)
        os.replace(tmp, POSITION_FILE)
    except Exception:
        pass


class OverlayApp:
    def __init__(self):
        self.root = tk.Tk()
        self.root.title("12V Guard")
        # A personal icon overrides the shipped project icon.
        for icon in (ICON_FILE, DEFAULT_ICON_FILE):
            if os.path.isfile(icon):
                try:
                    self.root.iconbitmap(icon)
                    break
                except tk.TclError:
                    pass  # unreadable/invalid icon; try the next one
        self.root.resizable(False, False)
        self.root.overrideredirect(False)
        self.root.attributes("-topmost", False)
        try:
            self.root.attributes("-alpha", WINDOW_ALPHA)
        except tk.TclError:
            pass  # some environments don't support per-window alpha; not fatal
        self.root.configure(bg=BG_COLOR)
        # Use the Windows dark title bar (attribute 20 = DWMWA_USE_IMMERSIVE_DARK_MODE,
        # Windows 10 20H1+/11). Best-effort: older builds just keep the light title bar.
        try:
            self.root.update_idletasks()
            hwnd = ctypes.windll.user32.GetParent(self.root.winfo_id())
            dark = ctypes.c_int(1)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                hwnd, 20, ctypes.byref(dark), ctypes.sizeof(dark)
            )
        except (OSError, AttributeError):
            pass

        x, y, scale, visible_stats = load_ui_state()
        self.scale = scale
        self.visible_stats = visible_stats
        self.root.geometry(f"+{x}+{y}")

        self._drag_origin = None
        self._build_ui()

        self.settings_popup: Optional[SettingsPopup] = None
        self._poll()

    def set_scale(self, new_scale: float) -> None:
        """Rebuild the whole UI at a new scale. Simpler and far less error-prone than
        trying to resize every already-placed widget/canvas in place, and this only
        runs on an explicit user action from the settings popup, not on a hot path."""
        new_scale = max(MIN_SCALE, min(MAX_SCALE, new_scale))
        if new_scale == self.scale:
            return
        self.scale = new_scale
        self._rebuild()

    def set_stat_visible(self, key: str, visible: bool) -> None:
        if self.visible_stats.get(key) == visible:
            return
        self.visible_stats[key] = visible
        self._rebuild()

    def _rebuild(self) -> None:
        """Tear down and recreate the UI frame in place - used by both set_scale()
        and set_stat_visible() since both need every widget's layout recomputed."""
        # Destroy only the frame _build_ui() itself created (self._outer), not every
        # child of root - the settings popup is a Toplevel child of root too, and
        # rebuilding while it's open must not tear it down out from under the user.
        self._outer.destroy()
        self._build_ui()
        save_ui_state(self.root.winfo_x(), self.root.winfo_y(), self.scale, self.visible_stats)

    # -- UI construction ------------------------------------------------
    def _build_ui(self) -> None:
        s = self.scale
        bar_width = round(BAR_WIDTH * s)
        bar_height = round(BAR_HEIGHT * s)
        bar_gap = round(BAR_GAP * s)
        pad_x = round(10 * s)
        pad_y = round(8 * s)
        title_font = ("Segoe UI", round(TITLE_FONT_SIZE * s), "bold")
        label_font = ("Segoe UI", round(LABEL_FONT_SIZE * s))
        small_font = ("Segoe UI", round(SMALL_FONT_SIZE * s))
        icon_font = ("Segoe UI", round(ICON_FONT_SIZE * s))

        outer = tk.Frame(self.root, bg=BG_COLOR, padx=pad_x, pady=pad_y)
        self._outer = outer
        outer.pack()
        outer.bind("<ButtonPress-1>", self._drag_start)
        outer.bind("<B1-Motion>", self._drag_move)

        header = tk.Frame(outer, bg=BG_COLOR)
        header.pack(fill="x")
        header.bind("<ButtonPress-1>", self._drag_start)
        header.bind("<B1-Motion>", self._drag_move)

        self.title_label = tk.Label(
            header, text="12VHPWR GUARD", fg=FG_COLOR, bg=BG_COLOR, font=title_font,
        )
        self.title_label.pack(side="left")

        settings_btn = tk.Label(
            header, text="⚙", fg=DIM_COLOR, bg=BG_COLOR, cursor="hand2", font=icon_font,
        )
        settings_btn.pack(side="right", padx=(6, 0))
        settings_btn.bind("<Button-1>", self._open_settings)

        self.gpu_name_label = tk.Label(
            outer, text="Waiting for guard...", fg=DIM_COLOR, bg=BG_COLOR, font=label_font,
        )
        self.gpu_name_label.pack(fill="x", pady=(2, round(8 * s)))

        bars_frame = tk.Frame(outer, bg=BG_COLOR)
        bars_frame.pack()
        bars_frame.bind("<ButtonPress-1>", self._drag_start)
        bars_frame.bind("<B1-Motion>", self._drag_move)

        self.bar_canvases = []
        self.bar_value_labels = []
        self._bar_height = bar_height  # remembered for _render()'s fill-height math
        for i in range(6):
            col = tk.Frame(bars_frame, bg=BG_COLOR)
            col.grid(row=0, column=i, padx=bar_gap // 2)

            canvas = tk.Canvas(
                col, width=bar_width, height=bar_height, bg=BAR_BG,
                highlightthickness=0,
            )
            canvas.pack()
            self.bar_canvases.append(canvas)

            value_label = tk.Label(
                col, text="--", fg=FG_COLOR, bg=BG_COLOR, font=label_font,
            )
            value_label.pack()
            self.bar_value_labels.append(value_label)

            pin_label = tk.Label(
                col, text=f"P{i + 1}", fg=DIM_COLOR, bg=BG_COLOR, font=small_font,
            )
            pin_label.pack()

        stats = tk.Frame(outer, bg=BG_COLOR)
        stats.pack(fill="x", pady=(round(8 * s), 0))

        self.stats_labels = {}
        self.stats_rows = {}
        for key, caption in STAT_FIELDS:
            if not self.visible_stats.get(key, True):
                continue
            row = tk.Frame(stats, bg=BG_COLOR)
            row.pack(fill="x")
            tk.Label(row, text=f"{caption}:", fg=DIM_COLOR, bg=BG_COLOR,
                     font=label_font, width=9, anchor="w").pack(side="left")
            value = tk.Label(row, text="--", fg=FG_COLOR, bg=BG_COLOR,
                              font=label_font, anchor="w")
            value.pack(side="left")
            self.stats_labels[key] = value
            self.stats_rows[key] = row

        self.status_label = tk.Label(
            outer, text="", fg=DIM_COLOR, bg=BG_COLOR, font=small_font,
        )
        self.status_label.pack(fill="x", pady=(round(6 * s), 0))

    # -- dragging ---------------------------------------------------------
    def _drag_start(self, event) -> None:
        self._drag_origin = (event.x_root, event.y_root,
                              self.root.winfo_x(), self.root.winfo_y())

    def _drag_move(self, event) -> None:
        if self._drag_origin is None:
            return
        ox, oy, wx, wy = self._drag_origin
        new_x = wx + (event.x_root - ox)
        new_y = wy + (event.y_root - oy)
        self.root.geometry(f"+{new_x}+{new_y}")

    def _on_drag_end(self) -> None:
        save_ui_state(self.root.winfo_x(), self.root.winfo_y(), self.scale, self.visible_stats)

    # -- settings -----------------------------------------------------------
    def _open_settings(self, _event=None) -> None:
        if self.settings_popup is not None and self.settings_popup.is_open():
            self.settings_popup.focus()
            return
        self.settings_popup = SettingsPopup(self.root, overlay_app=self)

    # -- polling / rendering --------------------------------------------
    def _poll(self) -> None:
        status = read_status()
        self._render(status)
        self.root.after(POLL_INTERVAL_MS, self._poll)

    def _render(self, status: Optional[dict]) -> None:
        if status is None:
            self._render_disconnected()
            return

        pins = status.get("pins") or []
        threshold = status.get("threshold_amps") or DEFAULT_THRESHOLD_AMPS
        telemetry = status.get("telemetry") or {}

        gpu_name = telemetry.get("gpu_name") or "Unknown GPU"
        self.gpu_name_label.config(text=gpu_name, fg=FG_COLOR)

        bar_h = self._bar_height
        bar_w = round(BAR_WIDTH * self.scale)
        for i in range(6):
            canvas = self.bar_canvases[i]
            canvas.delete("all")
            if i < len(pins):
                amps = pins[i].get("amps", 0.0)
                color = bar_color(amps, threshold)
                fill_frac = bar_fill_fraction(amps, threshold)
                fill_h = int(bar_h * fill_frac)
                canvas.create_rectangle(
                    0, bar_h - fill_h, bar_w, bar_h,
                    fill=color, outline="",
                )
                # Threshold marker line for a fixed visual reference point.
                marker_y = bar_h - int(bar_h * bar_fill_fraction(threshold, threshold))
                canvas.create_line(0, marker_y, bar_w, marker_y, fill="#555555")
                self.bar_value_labels[i].config(text=f"{amps:.1f}A")
            else:
                self.bar_value_labels[i].config(text="--")

        self._set_stat("power", self._fmt(telemetry.get("power_w"), "{:.0f} W"))
        voltages = status.get("pin_voltages")
        avg_v = (sum(voltages) / len(voltages)) if voltages else None
        self._set_stat("voltage", self._fmt(avg_v, "{:.2f} V"))
        self._set_stat("core_voltage", self._fmt(telemetry.get("core_voltage_v"), "{:.3f} V"))
        self._set_stat("clock", self._fmt(telemetry.get("clock_mhz"), "{} MHz"))
        used = telemetry.get("vram_used_bytes")
        total = telemetry.get("vram_total_bytes")
        if used is not None and total is not None:
            self._set_stat("vram", f"{used / 1e9:.1f} / {total / 1e9:.0f} GB")
        else:
            self._set_stat("vram", "N/A")
        self._set_stat("gpu_util", self._fmt(telemetry.get("gpu_util_pct"), "{}%"))
        self._set_stat("temp", self._fmt(telemetry.get("temp_c"), "{}°C"))

        elapsed_over = status.get("seconds_over_threshold", 0.0) or 0.0
        sustained_required = status.get("sustained_seconds_required", 0.0) or 0.0
        guard_status = status.get("guard_status", "")

        if guard_status == "MITIGATED":
            self.status_label.config(
                text="GPU LIMITED - protecting connector", fg="#e67e22")
        elif guard_status == "SHUTDOWN":
            self.status_label.config(text="SHUTTING DOWN", fg="#e74c3c")
        elif elapsed_over > 0.1:
            self.status_label.config(
                text=f"OVER THRESHOLD {elapsed_over:.1f}s / {sustained_required:.0f}s",
                fg="#e74c3c",
            )
        else:
            self.status_label.config(text=status.get("last_message", ""), fg=DIM_COLOR)

    def _render_disconnected(self) -> None:
        self.gpu_name_label.config(text="Guard not running / no data", fg="#e74c3c")
        for i in range(6):
            self.bar_canvases[i].delete("all")
            self.bar_value_labels[i].config(text="--")
        for label in self.stats_labels.values():
            label.config(text="--")
        self.status_label.config(text="Disconnected", fg="#e74c3c")

    def _set_stat(self, key: str, text: str) -> None:
        """No-op for a stat the user has hidden - _build_ui() never created a label
        for it, so self.stats_labels has no entry to update."""
        label = self.stats_labels.get(key)
        if label is not None:
            label.config(text=text)

    @staticmethod
    def _fmt(value, fmt: str) -> str:
        if value is None:
            return "N/A"
        try:
            return fmt.format(value)
        except Exception:
            return "N/A"

    def run(self) -> None:
        self.root.mainloop()


# Held for the process lifetime; Windows releases the mutex when the process exits.
_single_instance_handle = None


def acquire_single_instance() -> bool:
    """False when another overlay already runs in this logon session (e.g. the Start
    Menu shortcut clicked while the autostarted copy is open)."""
    global _single_instance_handle
    try:
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateMutexW.restype = ctypes.c_void_p
        ctypes.set_last_error(0)
        _single_instance_handle = kernel32.CreateMutexW(None, False, SINGLE_INSTANCE_MUTEX)
        return ctypes.get_last_error() != ERROR_ALREADY_EXISTS
    except Exception:
        return True  # never refuse to start just because the check itself failed


def main() -> None:
    if not acquire_single_instance():
        return
    app = OverlayApp()
    # Save position on release, not just during drag, so a click without a drag
    # doesn't spuriously rewrite the file every poll tick.
    app.root.bind_all("<ButtonRelease-1>", lambda _e: app._on_drag_end())
    app.run()


if __name__ == "__main__":
    main()
