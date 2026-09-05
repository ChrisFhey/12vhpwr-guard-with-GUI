"""
Color-bar gradient logic for the overlay. Pure functions, no Tkinter dependency, so
they can be unit tested without a display.
"""

from typing import Tuple

# Fractions of threshold at which the bar changes color. Below WARN_FRACTION: green.
# Between WARN_FRACTION and 1.0: yellow. At/above 1.0 (at or over threshold): red.
WARN_FRACTION = 0.70

COLOR_GREEN = (46, 204, 113)
COLOR_YELLOW = (241, 196, 15)
COLOR_RED = (231, 76, 60)
COLOR_GRAY = (120, 120, 120)  # disconnected / unknown


def _lerp(a: Tuple[int, int, int], b: Tuple[int, int, int], t: float) -> Tuple[int, int, int]:
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def bar_color(amps: float, threshold_amps: float) -> str:
    """Returns a Tkinter-compatible '#rrggbb' color for a given current reading.

    Smoothly ramps green -> yellow across [0, WARN_FRACTION * threshold], then
    yellow -> red across [WARN_FRACTION * threshold, threshold]. Clamps at red for
    anything at or above threshold rather than extrapolating further (a value far
    past threshold is exactly as urgent as one just past it, from a color standpoint;
    the number itself still shows the real reading).
    """
    if threshold_amps <= 0:
        return _to_hex(COLOR_GRAY)

    fraction = amps / threshold_amps
    warn_at = WARN_FRACTION

    if fraction <= 0:
        return _to_hex(COLOR_GREEN)
    if fraction < warn_at:
        return _to_hex(_lerp(COLOR_GREEN, COLOR_YELLOW, fraction / warn_at))
    if fraction < 1.0:
        return _to_hex(_lerp(COLOR_YELLOW, COLOR_RED, (fraction - warn_at) / (1.0 - warn_at)))
    return _to_hex(COLOR_RED)


def bar_fill_fraction(amps: float, threshold_amps: float, headroom: float = 1.5) -> float:
    """How full the bar should be drawn, as a 0..1 fraction of its max height/width.

    headroom means the bar's visual max represents `headroom * threshold`, not the
    threshold itself - so the user can see a pin climbing well before and after the
    threshold line, rather than the bar being permanently pegged at 100% during a
    real overcurrent event.
    """
    if threshold_amps <= 0:
        return 0.0
    return max(0.0, min(1.0, amps / (threshold_amps * headroom)))


def _to_hex(rgb: Tuple[int, int, int]) -> str:
    return "#{:02x}{:02x}{:02x}".format(*rgb)
