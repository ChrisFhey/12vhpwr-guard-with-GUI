"""
GPU core voltage via HWiNFO's SM2 shared memory - "GPU Core Voltage" sensor.

Why this instead of the undocumented NvAPI V/F-curve query: every published account
of that function's exact buffer layout (ClockClientClkVfPointsGetStatus, 0x21537AD4)
disagreed with itself on the arithmetic (a 7208-byte buffer that no combination of
documented header/point sizes actually adds up to), so implementing it would mean
guessing at the missing structure and handing a possibly-malformed buffer to an
undocumented driver call. HWiNFO already computes this value correctly and exposes it
by name over the same SM2 shared-memory mechanism this project already reads for pin
currents (see HwinfoBackend in hwinfo_12vhpwr_guard.py) - reusing that is safer than
reverse-engineering a second undocumented interface ourselves.

Requires HWiNFO Sensors running with "Shared Memory Support" enabled. Purely optional:
if HWiNFO isn't running, or shared memory isn't enabled, or the sensor isn't present
under any of the expected names, core voltage simply shows as unavailable - it never
affects the astral_i2c-based current readings or the threshold/shutdown decision,
which do not depend on this module at all.
"""

from typing import Optional

# HWiNFO's own sensor naming has varied by driver/HWiNFO version and forum reports
# (see hwinfo.com/forum threads on RTX 5090 "GPU Core Voltage" vs "Unknown Rail (10)
# Voltage" vs "GPU VDDC"). Trying several known names beats hardcoding one and silently
# reporting nothing on a HWiNFO version that phrases it differently.
CORE_VOLTAGE_SENSOR_NAMES = (
    "GPU Core Voltage",
    "GPU VDDC",
    "Core Voltage",
)


class CoreVoltageReader:
    """Read-only, best-effort GPU core voltage via HWiNFO SM2.

    Independent of HwinfoBackend (which reads pin currents): this must work whether
    the guard's chosen current source is the direct astral backend or HWiNFO, since
    core voltage is never available from the astral I2C chip at all.
    """

    def __init__(self, guard_module):
        """guard_module: the hwinfo_12vhpwr_guard module, passed in rather than
        imported, so this stays a plain reader with no import-time side effects and
        no risk of circular imports (hwinfo_12vhpwr_guard imports telemetry, which
        would import this)."""
        self._g = guard_module
        self._h_map = None
        self._view_ptr = None
        self._h_mutex = None
        self._connected = False

    @property
    def is_connected(self) -> bool:
        return self._connected

    def connect(self) -> bool:
        try:
            self._h_map, self._view_ptr, self._h_mutex = self._g.open_hwinfo_sm2()
            self._connected = True
            return True
        except Exception:
            self._connected = False
            return False

    def core_voltage(self) -> Optional[float]:
        if not self._connected:
            return None
        try:
            entries = self._g.read_entries(self._view_ptr, self._h_mutex)
        except Exception:
            self._connected = False
            return None

        targets = set(CORE_VOLTAGE_SENSOR_NAMES)
        for e in entries:
            name_orig = self._g._cstr(bytes(e.name_original))
            name_user = self._g._cstr(bytes(e.name_user))
            if name_orig in targets or name_user in targets:
                return float(e.value)
        return None

    def close(self) -> None:
        if self._connected:
            try:
                self._g.close_sm2(self._h_map, self._view_ptr, self._h_mutex)
            except Exception:
                pass
        self._h_map = self._view_ptr = self._h_mutex = None
        self._connected = False
