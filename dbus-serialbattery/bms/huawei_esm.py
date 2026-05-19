# -*- coding: utf-8 -*-
# Huawei SmartLi ESM-48xxx BMS driver for dbus-serialbattery
# Tested with: ESM-48150B1 (slave 214, 215) and ESM-48100B1 (slave 216)
# Protocol: Modbus RTU over RS485, 9600 8N1
# Slave addresses: 214-216 (configurable via Huawei app, range 214-231)
#
# AUTHENTICATION REQUIRED after every power cycle or reconnect:
#   Step 1 - FC03 read 7 registers at 0x0106 (unlock handshake)
#   Step 2 - FC10 write current datetime (6 registers) to 0x1000

import sys
import struct
import time
import configparser
import os
from datetime import datetime
from battery import Battery, Cell
from utils import logger, open_serial_port

DRIVER_VERSION = "1.3.0"

CONFIG_PATH = "/data/apps/dbus-serialbattery/config.ini"

# Modbus slave addresses for the 3 packs (validated in field)
# Format: (slave_id, capacity_ah, model_name, cells_in_series)
# cells_in_series: inferred from fault register 0x0047 which covers cells 1-16
PACK_CONFIG = [
    (214, 150, "ESM-48150B1", 16),
    (215, 150, "ESM-48150B1", 16),
    (216, 100, "ESM-48100B1", 16),
]

# Register map (validated against Huawei Battery Monitor repo, field-tested)
# Registers read as one contiguous block: _modbus_read(slave, REG_VOLTAGE, 7)
# returns vals[0..6] = voltage, _, current, soc, soh, temp_max, temp_min
REG_VOLTAGE  = 0x0000  # [0] Pack voltage,    0.01 V,  uint16
# 0x0001 reserved
# [1] offset 0x0001 unused
REG_CURRENT  = 0x0002  # [2] Pack current,    0.01 A,  int16 (two's complement > 32767)
REG_SOC      = 0x0003  # [3] SOC,             1 %,     uint16
REG_SOH      = 0x0004  # [4] SOH,             1 %,     uint16
REG_TEMP_MAX = 0x0005  # [5] Max cell temp,   1 deg C, uint16
REG_TEMP_MIN = 0x0006  # [6] Min cell temp,   1 deg C, uint16
REG_STATUS   = 0x000A  # Status bitfield (read separately), uint16
REG_UNLOCK   = 0x0106  # Auth step 1: read 7 regs
REG_DATETIME = 0x1000  # Auth step 2: write 6 regs (year,month,day,hour,min,sec)


def _read_ccl_from_config() -> float:
    """Return MAX_BATTERY_CHARGE_CURRENT from config.ini, or None if missing/unreadable."""
    try:
        cfg = configparser.ConfigParser()
        cfg.read(CONFIG_PATH)
        val = cfg["DEFAULT"].get("MAX_BATTERY_CHARGE_CURRENT")
        return float(val) if val is not None else None
    except Exception:
        return None


def _persist_ccl(new_ccl: float) -> None:
    """Rewrite MAX_BATTERY_CHARGE_CURRENT in config.ini without touching other keys."""
    try:
        cfg = configparser.ConfigParser()
        cfg.read(CONFIG_PATH)
        cfg["DEFAULT"]["MAX_BATTERY_CHARGE_CURRENT"] = str(int(new_ccl))
        with open(CONFIG_PATH, "w") as fh:
            cfg.write(fh)
        logger.info("Huawei ESM: persisted MAX_BATTERY_CHARGE_CURRENT=%.0f to config.ini", new_ccl)
    except Exception as exc:
        logger.warning("Huawei ESM: could not persist CCL to config.ini: %s", exc)


def _fmt_temp(t) -> str:
    return ("%.1f" % t) if t is not None else "--"


def _crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _build_read(slave: int, reg: int, count: int) -> bytes:
    frame = struct.pack(">BBHH", slave, 0x03, reg, count)
    return frame + struct.pack("<H", _crc16(frame))


def _build_write_multiple(slave: int, reg: int, values: list) -> bytes:
    n = len(values)
    frame = struct.pack(">BBHHB", slave, 0x10, reg, n, n * 2)
    for v in values:
        frame += struct.pack(">H", v)
    return frame + struct.pack("<H", _crc16(frame))


def _modbus_read(ser, slave: int, reg: int, count: int):
    ser.reset_input_buffer()
    ser.write(_build_read(slave, reg, count))
    time.sleep(0.4)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    if len(resp) < 5 or (resp[1] & 0x80):
        return None
    return [struct.unpack(">H", resp[3 + i*2: 5 + i*2])[0] for i in range(count)]


def _modbus_write(ser, slave: int, reg: int, values: list) -> bool:
    ser.reset_input_buffer()
    ser.write(_build_write_multiple(slave, reg, values))
    time.sleep(0.5)
    return len(ser.read(8)) >= 6


def _authenticate(ser, slave_id: int, model: str) -> bool:
    vals = _modbus_read(ser, slave_id, REG_UNLOCK, 7)
    if vals is None:
        logger.warning("Huawei ESM slave %d: auth step 1 failed", slave_id)
        return False
    time.sleep(0.3)
    now = datetime.now()
    ok = _modbus_write(ser, slave_id, REG_DATETIME,
                       [now.year, now.month, now.day, now.hour, now.minute, now.second])
    time.sleep(0.5)
    if not ok:
        logger.warning("Huawei ESM slave %d: auth step 2 (datetime write) failed", slave_id)
        return False
    logger.info("Huawei ESM slave %d (%s): authenticated OK", slave_id, model)
    return True


class HuaweiEsmPack:
    """Single Huawei ESM battery pack — holds last-read values."""

    def __init__(self, slave_id: int, capacity_ah: int, model: str, cells_in_series: int):
        self.slave_id        = slave_id
        self.capacity_ah     = capacity_ah
        self.model           = model
        self.cells_in_series = cells_in_series
        self.voltage         = 0.0
        self.current         = 0.0
        self.soc             = 0
        self.soh             = 0
        self.temp_max        = 0.0
        self.temp_min        = 0.0
        self.status          = 0
        self.online          = False
        self.authenticated   = False

    @property
    def temp_avg(self) -> float:
        return (self.temp_max + self.temp_min) / 2.0

    @property
    def cell_voltage_avg(self) -> float:
        if self.cells_in_series > 0 and self.voltage > 0:
            return self.voltage / self.cells_in_series
        return 0.0

    def refresh(self, ser) -> bool:
        if not self.authenticated:
            if not _authenticate(ser, self.slave_id, self.model):
                self.online = False
                return False
            self.authenticated = True

        vals = _modbus_read(ser, self.slave_id, REG_VOLTAGE, 7)
        if vals is None:
            logger.warning("Huawei ESM slave %d: read failed, will re-auth next cycle", self.slave_id)
            self.authenticated = False
            self.online = False
            return False

        self.voltage  = vals[0] * 0.01
        raw_i         = vals[2]
        self.current  = (raw_i - 65536 if raw_i > 32767 else raw_i) * 0.01
        self.soc      = vals[3]
        self.soh      = vals[4]
        self.temp_max = float(vals[5])
        self.temp_min = float(vals[6])

        sv = _modbus_read(ser, self.slave_id, REG_STATUS, 1)
        if sv:
            self.status = sv[0]

        self.online = True
        return True


class HuaweiEsm(Battery):
    """
    dbus-serialbattery driver for Huawei SmartLi ESM-48xxx battery banks.
    Polls 3 packs sequentially on one RS485 bus and presents an aggregated
    single battery to Venus OS / DVCC.

    Cell array layout (self.cells[]):
      - One Cell per cell_in_series slot per pack, ordered pack0..packN
      - cell.voltage = pack.voltage / cells_in_series (approximated average)
      - This populates Voltage (/Voltages/Sum), Cell max, Cell min in the GUI

    Temperature slots:
      - Temp 1 = avg temp pack 0  (temp_max + temp_min) / 2
      - Temp 2 = avg temp pack 1
      - Temp 3 = avg temp pack 2
    """

    BATTERYTYPE = "Huawei ESM"

    def __init__(self, port, baud, address=None):
        super(HuaweiEsm, self).__init__(port, baud, address)
        self.type = self.BATTERYTYPE
        self.poll_interval = 5000  # ms

        self.packs = [HuaweiEsmPack(sid, cap, mdl, cells) for sid, cap, mdl, cells in PACK_CONFIG]
        self.total_capacity_ah = sum(p.capacity_ah for p in self.packs)
        self.total_cells = sum(p.cells_in_series for p in self.packs)

        # LiFePO4: max 3.4375 V/cell, min 2.80 V/cell — scaled by actual cells_in_series
        max_cells = max(p.cells_in_series for p in self.packs)
        self.max_battery_voltage = 55.0              # overridden by CVL from config
        self.min_battery_voltage = max_cells * 2.80  # 44.8V for 16S

        # CCL: load from config.ini so GUI edits survive restarts
        saved_ccl = _read_ccl_from_config()
        if saved_ccl is not None:
            self.max_battery_charge_current = saved_ccl
        self._last_persisted_ccl = self.max_battery_charge_current

        # Initialize cell array so manage_charge_voltage doesn't crash before first refresh
        self.cell_count = self.total_cells
        self.capacity = float(self.total_capacity_ah)
        self.hardware_version = "Huawei ESM v%s" % DRIVER_VERSION
        for _ in range(self.cell_count):
            self.cells.append(Cell(False))

    def unique_identifier(self) -> str:
        # Fixed string independent of driver version so Venus OS always maps
        # this battery to the same DeviceInstance across upgrades/restarts.
        return "HuaweiESM_" + str(int(self.total_capacity_ah)) + "Ah"

    def test_connection(self) -> bool:
        logger.info("Huawei ESM: testing connection on %s", self.port)
        for attempt in range(20):
            try:
                with open_serial_port(self.port, self.baud_rate) as ser:
                    for pack in self.packs:
                        if _authenticate(ser, pack.slave_id, pack.model):
                            vals = _modbus_read(ser, pack.slave_id, REG_VOLTAGE, 7)
                            if vals is not None:
                                logger.info("Huawei ESM: connection OK via slave %d", pack.slave_id)
                                pack.authenticated = True
                                return True
                        time.sleep(0.2)
            except Exception:
                exc_type, exc_obj, exc_tb = sys.exc_info()
                logger.error(
                    "Huawei ESM: exception in test_connection: %s in %s line %d",
                    repr(exc_obj), exc_tb.tb_frame.f_code.co_filename, exc_tb.tb_lineno,
                )
            logger.info("Huawei ESM: test attempt %d/20 failed, retrying in 3s...", attempt + 1)
            time.sleep(3)
        return False

    def get_settings(self) -> bool:
        self.cell_count = self.total_cells
        self.capacity   = float(self.total_capacity_ah)
        self.hardware_version = "Huawei ESM v%s" % DRIVER_VERSION

        if len(self.cells) == 0:
            for _ in range(self.cell_count):
                self.cells.append(Cell(False))
        return True

    def refresh_data(self) -> bool:
        online = []

        try:
            with open_serial_port(self.port, self.baud_rate) as ser:
                for pack in self.packs:
                    try:
                        if pack.refresh(ser):
                            online.append(pack)
                    except Exception:
                        exc_type, exc_obj, exc_tb = sys.exc_info()
                        logger.error(
                            "Huawei ESM slave %d: exception: %s line %d",
                            pack.slave_id, repr(exc_obj), exc_tb.tb_lineno,
                        )
                    time.sleep(0.2)
        except Exception:
            exc_type, exc_obj, exc_tb = sys.exc_info()
            logger.error(
                "Huawei ESM: serial open failed: %s line %d",
                repr(exc_obj), exc_tb.tb_lineno,
            )
            return False

        if not online:
            logger.error("Huawei ESM: no packs online")
            return False

        # Aggregate: capacity-weighted SOC, average voltage, sum of currents
        total_cap    = sum(p.capacity_ah for p in online)
        self.voltage = sum(p.voltage for p in online) / len(online)
        self.current = sum(p.current for p in online)
        self.soc     = sum(p.soc * p.capacity_ah for p in online) / total_cap
        self.soh     = sum(p.soh for p in online) / len(online)
        self.capacity = float(total_cap)

        # Populate cell array with approximated per-cell voltage (pack_voltage / cells_in_series)
        # This allows the GUI to show Voltage (sum), Cell max, and Cell min
        cell_idx = 0
        for pack in self.packs:
            v = pack.cell_voltage_avg if pack.online else 0.0
            for _ in range(pack.cells_in_series):
                if cell_idx < len(self.cells):
                    self.cells[cell_idx].voltage = v
                cell_idx += 1

        # Temperatures: (temp_max + temp_min) / 2 per pack
        # Temp 1 = pack 0, Temp 2 = pack 1, Temp 3 = pack 2
        # Direct assignment for all slots: to_temperature() crashes on None input
        pack_temps = [p.temp_avg if p.online else None for p in self.packs]
        self.temperature_1 = pack_temps[0]
        self.temperature_2 = pack_temps[1]
        self.temperature_3 = pack_temps[2] if len(pack_temps) > 2 else None
        self.temperature_4 = None

        # FETs always on — BMS manages its own protection
        self.charge_fet    = True
        self.discharge_fet = True

        # Raise cell_imbalance alarm if any pack is offline
        offline_count = sum(1 for p in self.packs if not p.online)
        self.protection.cell_imbalance = 2 if offline_count else 0

        # Persist CCL if user changed it via GUI (/Info/MaxChargeCurrent writeable=True)
        ccl = self.max_battery_charge_current
        if ccl is not None and ccl != self._last_persisted_ccl:
            _persist_ccl(ccl)
            self._last_persisted_ccl = ccl

        logger.info(
            "Huawei ESM: %d/%d packs | V=%.2fV Vcell=%.3fV I=%.2fA SOC=%.0f%% SOH=%.0f%% "
            "CCL=%.0fA T1=%s T2=%s T3=%s",
            len(online), len(self.packs),
            self.voltage,
            sum(p.cell_voltage_avg for p in online) / len(online),
            self.current, self.soc, self.soh,
            ccl if ccl is not None else 0,
            _fmt_temp(pack_temps[0]),
            _fmt_temp(pack_temps[1]),
            _fmt_temp(pack_temps[2] if len(pack_temps) > 2 else None),
        )
        return True
