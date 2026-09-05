"""
Extra GPU telemetry for the overlay: power, temperature, clock, VRAM, utilization, name.

Nothing here feeds the threshold/shutdown decision - that path only ever uses per-pin
current from astral_i2c.py / hwinfo backend, unchanged. This module exists purely to
enrich the status snapshot the overlay reads. A call failing here must never affect
protection: every reading is independently best-effort and degrades to None.

Reuses gpu_mitigation._Nvml's binding pattern (ctypes over nvml.dll) rather than adding
a second NVML wrapper. Deliberately does NOT reuse gpu_mitigation's shared _Nvml
instance: that one is only connected lazily when tiered mitigation is actually needed,
and must not be forced into existence just to read telemetry (would misrepresent
mitigation availability and could trip elevation-dependent codepaths unnecessarily).
This module owns its own independent, unprivileged, read-only NVML connection.

VERIFIED (2026-09-05) against NVIDIA's own NVML API reference:
  nvmlDeviceGetPowerUsage(device, uint* power)              -> mW
  nvmlDeviceGetTemperature(device, NVML_TEMPERATURE_GPU, uint* temp) -> degrees C
  nvmlDeviceGetUtilizationRates(device, nvmlUtilization_t*) -> .gpu / .memory percent
  nvmlDeviceGetMemoryInfo_v2(device, nvmlMemory_v2_t*)      -> .used / .total bytes
    (v2 preferred; v1 nvmlDeviceGetMemoryInfo is deprecated but kept as a fallback for
    older drivers that lack v2)
  nvmlDeviceGetName (already bound in gpu_mitigation._Nvml, reused here)

KNOWN RISK: NVIDIA's own docs and multiple developer-forum reports confirm GeForce
("Limited Support" tier in NVML) can return NVML_ERROR_NOT_SUPPORTED for some of these
calls on some models/drivers even though the card exposes the value elsewhere. Every
call below is independently wrapped; a single failure yields None for that field only.

Core voltage (~0.8V) is deliberately NOT read here: NVML has no such call (confirmed
against NVIDIA's own docs and developer forum), and the only way to get it is an
undocumented, unpublished NvAPI function whose exact buffer layout could not be
verified from any available source (the arithmetic in every public account of it
didn't add up). See hwinfo_voltage.py for how core voltage is actually sourced
instead (HWiNFO SM2, optional, degrades to None with zero impact if unavailable).
"""

import ctypes
from typing import Optional

from gpu_mitigation import _Nvml, NVML_CLOCK_GRAPHICS

NVML_TEMPERATURE_GPU = 0


class NvmlUtilization(ctypes.Structure):
    _fields_ = [
        ("gpu", ctypes.c_uint32),
        ("memory", ctypes.c_uint32),
    ]


class NvmlMemoryV1(ctypes.Structure):
    _fields_ = [
        ("total", ctypes.c_uint64),
        ("free", ctypes.c_uint64),
        ("used", ctypes.c_uint64),
    ]


class NvmlMemoryV2(ctypes.Structure):
    """nvmlMemory_v2_t. version must be set before the call; struct is versioned."""
    _fields_ = [
        ("version", ctypes.c_uint32),
        ("total", ctypes.c_uint64),
        ("reserved", ctypes.c_uint64),
        ("free", ctypes.c_uint64),
        ("used", ctypes.c_uint64),
    ]


NVML_MEMORY_V2_VER = ctypes.sizeof(NvmlMemoryV2) | (2 << 24)


class TelemetryReader:
    """Independent, read-only NVML connection for the overlay's extra stats.

    connect() never raises: absence of a driver, or a card NVML cannot see, is a
    normal "unavailable" answer and the caller falls back to showing "N/A".
    """

    def __init__(self):
        self._nvml: Optional[_Nvml] = None
        self._handle = None
        self._have_mem_v2 = False

    def connect(self, subsystem_id: Optional[int] = None) -> bool:
        nvml = _Nvml()
        try:
            nvml.init()
        except Exception:
            return False

        try:
            handle = self._find_handle(nvml, subsystem_id)
            if handle is None:
                nvml.shutdown()
                return False
        except Exception:
            try:
                nvml.shutdown()
            except Exception:
                pass
            return False

        # Bind the extra calls this module needs, on top of what _Nvml.init() already
        # bound. Each is optional: a driver/card that lacks one must not break the rest.
        self._bind_extra(nvml)

        self._nvml = nvml
        self._handle = handle
        return True

    def _find_handle(self, nvml: _Nvml, subsystem_id: Optional[int]):
        count = nvml.device_count()
        handles = []
        for i in range(count):
            try:
                h = nvml.handle(i)
                handles.append((h, nvml.subsystem_id(h)))
            except Exception:
                continue

        if subsystem_id is not None:
            for h, sub in handles:
                if sub == subsystem_id:
                    return h

        if len(handles) == 1:
            return handles[0][0]
        return handles[0][0] if handles else None

    def _bind_extra(self, nvml: _Nvml) -> None:
        c_uint_p = ctypes.POINTER(ctypes.c_uint32)
        nvml._bind("nvmlDeviceGetPowerUsage", ctypes.c_int,
                   [ctypes.c_void_p, c_uint_p], required=False)
        nvml._bind("nvmlDeviceGetTemperature", ctypes.c_int,
                   [ctypes.c_void_p, ctypes.c_int, c_uint_p], required=False)
        nvml._bind("nvmlDeviceGetUtilizationRates", ctypes.c_int,
                   [ctypes.c_void_p, ctypes.POINTER(NvmlUtilization)], required=False)
        v2 = nvml._bind("nvmlDeviceGetMemoryInfo_v2", ctypes.c_int,
                         [ctypes.c_void_p, ctypes.POINTER(NvmlMemoryV2)], required=False)
        self._have_mem_v2 = v2 is not None
        if not self._have_mem_v2:
            nvml._bind("nvmlDeviceGetMemoryInfo", ctypes.c_int,
                       [ctypes.c_void_p, ctypes.POINTER(NvmlMemoryV1)], required=False)

    # -- individually best-effort readings -----------------------------------
    def name(self) -> Optional[str]:
        if self._nvml is None:
            return None
        try:
            return self._nvml.name(self._handle)
        except Exception:
            return None

    def power_watts(self) -> Optional[float]:
        if self._nvml is None:
            return None
        try:
            mw = ctypes.c_uint32(0)
            self._nvml._call("nvmlDeviceGetPowerUsage", self._handle, ctypes.byref(mw))
            return mw.value / 1000.0
        except Exception:
            return None

    def temperature_c(self) -> Optional[int]:
        if self._nvml is None:
            return None
        try:
            temp = ctypes.c_uint32(0)
            self._nvml._call("nvmlDeviceGetTemperature", self._handle,
                              ctypes.c_int(NVML_TEMPERATURE_GPU), ctypes.byref(temp))
            return int(temp.value)
        except Exception:
            return None

    def clock_mhz(self) -> Optional[int]:
        if self._nvml is None:
            return None
        try:
            clock = ctypes.c_uint32(0)
            self._nvml._call("nvmlDeviceGetClockInfo", self._handle,
                              ctypes.c_int(NVML_CLOCK_GRAPHICS), ctypes.byref(clock))
            return int(clock.value)
        except Exception:
            return None

    def utilization_percent(self) -> Optional[int]:
        if self._nvml is None:
            return None
        try:
            util = NvmlUtilization()
            self._nvml._call("nvmlDeviceGetUtilizationRates", self._handle, ctypes.byref(util))
            return int(util.gpu)
        except Exception:
            return None

    def memory_bytes(self):
        """Returns (used, total) in bytes, or (None, None) on any failure."""
        if self._nvml is None:
            return None, None
        try:
            if self._have_mem_v2:
                mem = NvmlMemoryV2()
                mem.version = NVML_MEMORY_V2_VER
                self._nvml._call("nvmlDeviceGetMemoryInfo_v2", self._handle, ctypes.byref(mem))
            else:
                mem = NvmlMemoryV1()
                self._nvml._call("nvmlDeviceGetMemoryInfo", self._handle, ctypes.byref(mem))
            return int(mem.used), int(mem.total)
        except Exception:
            return None, None

    def snapshot(self, core_voltage: Optional[float] = None) -> dict:
        """One dict of every reading, each independently None on failure.

        core_voltage is supplied by the caller (from hwinfo_voltage.CoreVoltageReader,
        an entirely separate HWiNFO-backed reader) rather than read here - this class
        only ever talks to NVML, and core voltage isn't available through NVML at all
        (confirmed: no such call exists in NVIDIA's public API)."""
        used, total = self.memory_bytes()
        return {
            "gpu_name": self.name(),
            "power_w": self.power_watts(),
            "temp_c": self.temperature_c(),
            "clock_mhz": self.clock_mhz(),
            "gpu_util_pct": self.utilization_percent(),
            "vram_used_bytes": used,
            "vram_total_bytes": total,
            "core_voltage_v": core_voltage,
        }

    def close(self) -> None:
        if self._nvml is not None:
            try:
                self._nvml.shutdown()
            except Exception:
                pass
        self._nvml = None
        self._handle = None
