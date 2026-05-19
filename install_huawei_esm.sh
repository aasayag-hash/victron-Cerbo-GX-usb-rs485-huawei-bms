#!/bin/bash
# =============================================================================
# Instalador de driver Huawei SmartLi ESM para dbus-serialbattery en Venus OS
# Uso: bash install_huawei_esm.sh
# Requiere: conexion a internet en el Cerbo GX
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "  ${CYAN}>>${NC} $1"; }

echo ""
echo "=============================================="
echo "  Huawei SmartLi ESM - Instalador Venus OS"
echo "=============================================="
echo ""

# ------------------------------------------------------------------------------
# 1. Puerto serie
# ------------------------------------------------------------------------------
read -p "Puerto USB-RS485 [/dev/ttyUSB0]: " TTY
TTY=${TTY:-/dev/ttyUSB0}
[ -e "$TTY" ] || err "Puerto $TTY no encontrado. Verifica que el adaptador USB-RS485 este conectado."

# ------------------------------------------------------------------------------
# 2. Auto-discovery de baterias via Python
# ------------------------------------------------------------------------------
echo ""
echo "--- Buscando baterias Huawei ESM en el bus RS485 ---"
echo "Escaneando slaves 214-231 (puede tardar hasta 60 segundos)..."
echo ""

DISCOVERY_RESULT=$(python3 - "$TTY" << 'PYEOF'
import sys, struct, time, serial
from datetime import datetime

port = sys.argv[1]

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc

def build_read(slave, reg, count):
    frame = struct.pack(">BBHH", slave, 0x03, reg, count)
    return frame + struct.pack("<H", crc16(frame))

def build_write(slave, reg, values):
    n = len(values)
    frame = struct.pack(">BBHHB", slave, 0x10, reg, n, n * 2)
    for v in values:
        frame += struct.pack(">H", v)
    return frame + struct.pack("<H", crc16(frame))

def read_regs(ser, slave, reg, count):
    ser.reset_input_buffer()
    ser.write(build_read(slave, reg, count))
    time.sleep(0.5)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    if len(resp) < 5 or (resp[1] & 0x80):
        return None
    return [struct.unpack(">H", resp[3+i*2:5+i*2])[0] for i in range(count)]

def authenticate(ser, slave):
    vals = read_regs(ser, slave, 0x0106, 7)
    if vals is None:
        return False
    time.sleep(0.3)
    now = datetime.now()
    ser.reset_input_buffer()
    ser.write(build_write(slave, 0x1000,
              [now.year, now.month, now.day, now.hour, now.minute, now.second]))
    time.sleep(0.5)
    ser.read(8)
    return True

# Model detection: capacity from register 0x0107, cells_in_series from fault reg 0x0047
# ESM-48xxxB1 all use 16S (confirmed via fault register covering cells 1-16)
MODEL_MAP = {
    150: ("ESM-48150B1", 16),
    100: ("ESM-48100B1", 16),
    200: ("ESM-48200B1", 16),
    75:  ("ESM-48075B1", 16),
}

found = []
try:
    ser = serial.Serial(port, baudrate=9600, bytesize=8, parity="N", stopbits=1, timeout=1)
    for slave in range(214, 232):
        sys.stderr.write(f"  Probando slave {slave}...\r")
        sys.stderr.flush()
        if authenticate(ser, slave):
            vals = read_regs(ser, slave, 0x0000, 7)
            if vals is not None:
                voltage = vals[0] * 0.01
                soc = vals[3]
                cap_vals = read_regs(ser, slave, 0x0107, 1)
                cap_ah = cap_vals[0] if cap_vals else 0
                model, cells = MODEL_MAP.get(cap_ah, (f"ESM-48xxxB1", 16))
                found.append((slave, cap_ah, model, cells, voltage, soc))
        time.sleep(0.2)
    ser.close()
except Exception as e:
    sys.stderr.write(f"\nError: {e}\n")

sys.stderr.write("\n")
for slave, cap, model, cells, voltage, soc in found:
    print(f"{slave}|{cap}|{model}|{cells}|{voltage:.2f}|{soc}")
PYEOF
)

if [ -z "$DISCOVERY_RESULT" ]; then
    echo ""
    warn "No se encontraron baterias en el bus. Opciones:"
    echo "  1) Verificar cableado RS485"
    echo "  2) Verificar que las baterias esten encendidas"
    echo "  3) Ingresar configuracion manual"
    echo ""
    read -p "Ingresar configuracion manual? [S/n]: " DO_MANUAL
    DO_MANUAL=${DO_MANUAL:-S}
    if [[ ! "$DO_MANUAL" =~ ^[Ss]$ ]]; then
        err "Instalacion cancelada."
    fi
    MANUAL_MODE=1
else
    echo "Baterias encontradas:"
    echo ""
    FOUND_COUNT=0
    while IFS='|' read -r slave cap model cells voltage soc; do
        echo "  Slave $slave: $model  ${cap}Ah  ${cells}S  ${voltage}V  SOC=${soc}%"
        FOUND_COUNT=$((FOUND_COUNT + 1))
    done <<< "$DISCOVERY_RESULT"
    echo ""
    ok "$FOUND_COUNT bateria(s) detectada(s)"
    echo ""
    read -p "Usar estas baterias detectadas? [S/n]: " USE_DETECTED
    USE_DETECTED=${USE_DETECTED:-S}
    if [[ ! "$USE_DETECTED" =~ ^[Ss]$ ]]; then
        MANUAL_MODE=1
    fi
fi

# ------------------------------------------------------------------------------
# 3. Construir PACK_CONFIG
# ------------------------------------------------------------------------------
if [ "${MANUAL_MODE:-0}" = "1" ]; then
    echo ""
    echo "--- Configuracion manual de baterias ---"
    read -p "Cantidad de baterias [1-10]: " NUM_PACKS
    PACK_CONFIG="["
    TOTAL_AH=0
    for i in $(seq 1 $NUM_PACKS); do
        echo "  Bateria $i:"
        read -p "    Slave ID Modbus (ej: 214): "    SLAVE
        read -p "    Capacidad Ah (ej: 150): "        CAP
        read -p "    Modelo (ej: ESM-48150B1): "      MODEL
        read -p "    Celdas en serie (ej: 16): "      CELLS
        CELLS=${CELLS:-16}
        PACK_CONFIG+="($SLAVE, $CAP, \"$MODEL\", $CELLS), "
        TOTAL_AH=$((TOTAL_AH + CAP))
    done
    PACK_CONFIG="${PACK_CONFIG%, }]"
else
    PACK_CONFIG="["
    TOTAL_AH=0
    while IFS='|' read -r slave cap model cells voltage soc; do
        PACK_CONFIG+="($slave, $cap, \"$model\", $cells), "
        TOTAL_AH=$((TOTAL_AH + cap))
    done <<< "$DISCOVERY_RESULT"
    PACK_CONFIG="${PACK_CONFIG%, }]"
fi

# ------------------------------------------------------------------------------
# 4. Limites de carga/descarga
# ------------------------------------------------------------------------------
echo ""
echo "--- Limites de carga/descarga ---"
read -p "Corriente maxima de CARGA en A [12]: "    CCL
read -p "Corriente maxima de DESCARGA en A [60]: " DCL
read -p "Voltaje maximo de carga en V [55.0]: "    CVL
CCL=${CCL:-12}
DCL=${DCL:-60}
CVL=${CVL:-55.0}

# ------------------------------------------------------------------------------
# 5. Resumen y confirmacion
# ------------------------------------------------------------------------------
echo ""
echo "--- Resumen de instalacion ---"
info "Puerto:    $TTY"
info "Baterias:  $PACK_CONFIG"
info "Total:     ${TOTAL_AH}Ah"
info "CCL: ${CCL}A  |  DCL: ${DCL}A  |  CVL: ${CVL}V"
echo ""
read -p "Continuar con la instalacion? [S/n]: " CONFIRM
CONFIRM=${CONFIRM:-S}
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { echo "Instalacion cancelada."; exit 0; }

# ------------------------------------------------------------------------------
# 6. Verificar conexion a internet
# ------------------------------------------------------------------------------
echo ""
echo "--- Verificando conexion a internet ---"
wget -q --spider https://github.com || err "Sin conexion a internet."
ok "Conexion OK"

# ------------------------------------------------------------------------------
# 7. Instalar dbus-serialbattery
# ------------------------------------------------------------------------------
echo ""
echo "--- Instalando dbus-serialbattery ---"

if [ -f /data/apps/dbus-serialbattery/enable.sh ]; then
    warn "dbus-serialbattery ya instalado, saltando descarga."
else
    info "Descargando..."
    wget -q -O /tmp/dsb.zip https://github.com/mr-manuel/venus-os_dbus-serialbattery/archive/refs/heads/master.zip
    info "Descomprimiendo..."
    unzip -q /tmp/dsb.zip -d /tmp/
    mkdir -p /data/apps/dbus-serialbattery /data/etc/dbus-serialbattery
    cp -r /tmp/venus-os_dbus-serialbattery-master/etc/dbus-serialbattery/. /data/apps/dbus-serialbattery/
    cp -r /tmp/venus-os_dbus-serialbattery-master/etc/dbus-serialbattery/. /data/etc/dbus-serialbattery/
    rm -f /tmp/dsb.zip
    rm -rf /tmp/venus-os_dbus-serialbattery-master
    ok "dbus-serialbattery descargado"
fi

# ------------------------------------------------------------------------------
# 8. Instalar overlay-fs
# ------------------------------------------------------------------------------
echo ""
echo "--- Instalando overlay-fs ---"
if [ -f /data/apps/dbus-serialbattery/ext/venus-os_overlay-fs/install.sh ]; then
    bash /data/apps/dbus-serialbattery/ext/venus-os_overlay-fs/install.sh --copy 2>&1 | grep -E "completed|OK|ERROR" || true
    ok "overlay-fs instalado"
else
    warn "overlay-fs no encontrado en el paquete, continuando..."
fi

# ------------------------------------------------------------------------------
# 9. Escribir driver huawei_esm.py
# ------------------------------------------------------------------------------
echo ""
echo "--- Escribiendo driver huawei_esm.py ---"

DRIVER_PATH=/data/apps/dbus-serialbattery/bms/huawei_esm.py

cat > "$DRIVER_PATH" << DRIVER_EOF
# -*- coding: utf-8 -*-
# Huawei SmartLi ESM-48xxx BMS driver for dbus-serialbattery
# Protocol: Modbus RTU over RS485, 9600 8N1
# Auto-generated by install_huawei_esm.sh

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

# Format: (slave_id, capacity_ah, model_name, cells_in_series)
PACK_CONFIG = ${PACK_CONFIG}

REG_VOLTAGE  = 0x0000
REG_CURRENT  = 0x0002
REG_SOC      = 0x0003
REG_SOH      = 0x0004
REG_TEMP_MAX = 0x0005
REG_TEMP_MIN = 0x0006
REG_STATUS   = 0x000A
REG_UNLOCK   = 0x0106
REG_DATETIME = 0x1000


def _read_ccl_from_config():
    try:
        cfg = configparser.ConfigParser()
        cfg.read(CONFIG_PATH)
        val = cfg["DEFAULT"].get("MAX_BATTERY_CHARGE_CURRENT")
        return float(val) if val is not None else None
    except Exception:
        return None


def _persist_ccl(new_ccl):
    try:
        cfg = configparser.ConfigParser()
        cfg.read(CONFIG_PATH)
        cfg["DEFAULT"]["MAX_BATTERY_CHARGE_CURRENT"] = str(int(new_ccl))
        with open(CONFIG_PATH, "w") as fh:
            cfg.write(fh)
        logger.info("Huawei ESM: persisted MAX_BATTERY_CHARGE_CURRENT=%.0f to config.ini", new_ccl)
    except Exception as exc:
        logger.warning("Huawei ESM: could not persist CCL to config.ini: %s", exc)


def _fmt_temp(t):
    return ("%.1f" % t) if t is not None else "--"


def _crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def _build_read(slave, reg, count):
    frame = struct.pack(">BBHH", slave, 0x03, reg, count)
    return frame + struct.pack("<H", _crc16(frame))


def _build_write_multiple(slave, reg, values):
    n = len(values)
    frame = struct.pack(">BBHHB", slave, 0x10, reg, n, n * 2)
    for v in values:
        frame += struct.pack(">H", v)
    return frame + struct.pack("<H", _crc16(frame))


def _modbus_read(ser, slave, reg, count):
    ser.reset_input_buffer()
    ser.write(_build_read(slave, reg, count))
    time.sleep(0.4)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    if len(resp) < 5 or (resp[1] & 0x80):
        return None
    return [struct.unpack(">H", resp[3 + i*2: 5 + i*2])[0] for i in range(count)]


def _modbus_write(ser, slave, reg, values):
    ser.reset_input_buffer()
    ser.write(_build_write_multiple(slave, reg, values))
    time.sleep(0.5)
    return len(ser.read(8)) >= 6


def _authenticate(ser, slave_id, model):
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
    def __init__(self, slave_id, capacity_ah, model, cells_in_series):
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
    def temp_avg(self):
        return (self.temp_max + self.temp_min) / 2.0

    @property
    def cell_voltage_avg(self):
        if self.cells_in_series > 0 and self.voltage > 0:
            return self.voltage / self.cells_in_series
        return 0.0

    def refresh(self, ser):
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

    BATTERYTYPE = "Huawei ESM"

    def __init__(self, port, baud, address=None):
        super(HuaweiEsm, self).__init__(port, baud, address)
        self.type = self.BATTERYTYPE
        self.poll_interval = 5000

        self.packs = [HuaweiEsmPack(sid, cap, mdl, cells) for sid, cap, mdl, cells in PACK_CONFIG]
        self.total_capacity_ah = sum(p.capacity_ah for p in self.packs)
        self.total_cells = sum(p.cells_in_series for p in self.packs)

        # LiFePO4: min 2.80 V/cell scaled by actual cells_in_series
        max_cells = max(p.cells_in_series for p in self.packs)
        self.max_battery_voltage = ${CVL}
        self.min_battery_voltage = max_cells * 2.80

        self.cell_count = self.total_cells
        self.capacity = float(self.total_capacity_ah)
        self.hardware_version = "Huawei ESM v%s" % DRIVER_VERSION
        for _ in range(self.cell_count):
            self.cells.append(Cell(False))

        # CCL: load from config.ini so GUI edits survive restarts
        saved_ccl = _read_ccl_from_config()
        if saved_ccl is not None:
            self.max_battery_charge_current = saved_ccl
        self._last_persisted_ccl = self.max_battery_charge_current

    def unique_identifier(self):
        # Fixed string independent of driver version so Venus OS always maps
        # this battery to the same DeviceInstance across upgrades/restarts.
        return "HuaweiESM_" + str(int(self.total_capacity_ah)) + "Ah"

    def test_connection(self):
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
                logger.error("Huawei ESM: exception in test_connection: %s line %d",
                             repr(exc_obj), exc_tb.tb_lineno)
            logger.info("Huawei ESM: test attempt %d/20 failed, retrying in 3s...", attempt + 1)
            time.sleep(3)
        return False

    def get_settings(self):
        self.cell_count = self.total_cells
        self.capacity   = float(self.total_capacity_ah)
        self.hardware_version = "Huawei ESM v%s" % DRIVER_VERSION
        if len(self.cells) == 0:
            for _ in range(self.cell_count):
                self.cells.append(Cell(False))
        return True

    def refresh_data(self):
        online = []
        try:
            with open_serial_port(self.port, self.baud_rate) as ser:
                for pack in self.packs:
                    try:
                        if pack.refresh(ser):
                            online.append(pack)
                    except Exception:
                        exc_type, exc_obj, exc_tb = sys.exc_info()
                        logger.error("Huawei ESM slave %d: exception: %s line %d",
                                     pack.slave_id, repr(exc_obj), exc_tb.tb_lineno)
                    time.sleep(0.2)
        except Exception:
            exc_type, exc_obj, exc_tb = sys.exc_info()
            logger.error("Huawei ESM: serial open failed: %s line %d",
                         repr(exc_obj), exc_tb.tb_lineno)
            return False

        if not online:
            logger.error("Huawei ESM: no packs online")
            return False

        total_cap    = sum(p.capacity_ah for p in online)
        self.voltage = sum(p.voltage for p in online) / len(online)
        self.current = sum(p.current for p in online)
        self.soc     = sum(p.soc * p.capacity_ah for p in online) / total_cap
        self.soh     = sum(p.soh for p in online) / len(online)
        self.capacity = float(total_cap)

        # Populate cell array: one slot per cell per pack, voltage = pack_voltage / cells_in_series
        # Enables Cell max, Cell min and Voltage display in dbus-serialbattery GUI
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

        self.charge_fet    = True
        self.discharge_fet = True

        offline_count = sum(1 for p in self.packs if not p.online)
        self.protection.cell_imbalance = 2 if offline_count else 0

        # Persist CCL if user changed it via GUI (/Info/MaxChargeCurrent writeable=True)
        ccl = self.max_battery_charge_current
        if ccl is not None and ccl != self._last_persisted_ccl:
            _persist_ccl(ccl)
            self._last_persisted_ccl = ccl

        logger.info(
            "Huawei ESM: %d/%d packs | V=%.2fV Vcell=%.3fV I=%.2fA SOC=%.0f%% SOH=%.0f%% CCL=%.0fA T1=%s T2=%s T3=%s",
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
DRIVER_EOF

cp "$DRIVER_PATH" /data/etc/dbus-serialbattery/bms/huawei_esm.py
ok "Driver escrito"

# ------------------------------------------------------------------------------
# 10. Parchear dbus-serialbattery.py
# ------------------------------------------------------------------------------
echo ""
echo "--- Parcheando dbus-serialbattery.py ---"
MAIN=/data/apps/dbus-serialbattery/dbus-serialbattery.py

if grep -q "HuaweiEsm" "$MAIN"; then
    warn "Patch ya aplicado, saltando."
else
    LAST_BMS_IMPORT=$(grep -n "^from bms\." "$MAIN" | tail -1 | cut -d: -f1)
    sed -i "${LAST_BMS_IMPORT}a from bms.huawei_esm import HuaweiEsm" "$MAIN"
    CLOSE_BRACKET=$(grep -n "^]$" "$MAIN" | head -1 | cut -d: -f1)
    sed -i "${CLOSE_BRACKET}i\\    {\"bms\": HuaweiEsm, \"baud\": 9600, \"address\": b\"\\\\xd6\"}," "$MAIN"
    ok "dbus-serialbattery.py parcheado"
fi

# ------------------------------------------------------------------------------
# 11. Parchear dbushelper.py (fix temperature None)
# ------------------------------------------------------------------------------
echo ""
echo "--- Parcheando dbushelper.py ---"
HELPER=/data/apps/dbus-serialbattery/dbushelper.py

if grep -q "if self.battery.temperature_3 is not None" "$HELPER"; then
    warn "Patch ya aplicado, saltando."
else
    sed -i 's/self\.battery\.temperature_3 = (self\.battery\.temperature_3/if self.battery.temperature_3 is not None:\n                    self.battery.temperature_3 = (self.battery.temperature_3/' "$HELPER"
    sed -i 's/self\.battery\.temperature_4 = (self\.battery\.temperature_4/if self.battery.temperature_4 is not None:\n                    self.battery.temperature_4 = (self.battery.temperature_4/' "$HELPER"
    sed -i 's/self\.battery\.temperature_mos = (self\.battery\.temperature_mos/if self.battery.temperature_mos is not None:\n                    self.battery.temperature_mos = (self.battery.temperature_mos/' "$HELPER"
    ok "dbushelper.py parcheado"
fi

# ------------------------------------------------------------------------------
# 12. Escribir config.ini
# ------------------------------------------------------------------------------
echo ""
echo "--- Escribiendo config.ini ---"
cat > /data/apps/dbus-serialbattery/config.ini << CONFIG_EOF
[DEFAULT]
BMS_TYPE = HuaweiEsm
MAX_BATTERY_CHARGE_CURRENT = ${CCL}
MAX_BATTERY_DISCHARGE_CURRENT = ${DCL}
CVCM_ENABLE = False
CONFIG_EOF
ok "config.ini escrito"

# ------------------------------------------------------------------------------
# 13. Configurar serial-starter
# ------------------------------------------------------------------------------
echo ""
echo "--- Configurando serial-starter ---"
mkdir -p /data/conf/serial-starter.d
cat > /data/conf/serial-starter.d/dbus-serialbattery.conf << SERIAL_EOF
service sbattery dbus-serialbattery
alias cgwacs sbattery
alias rs485 sbattery
alias default sbattery
SERIAL_EOF
ok "serial-starter configurado"

# ------------------------------------------------------------------------------
# 14. Correr enable.sh
# ------------------------------------------------------------------------------
echo ""
echo "--- Ejecutando enable.sh ---"
bash /data/apps/dbus-serialbattery/enable.sh 2>&1 | grep -E "installed|completed|error|Error" || true
ok "enable.sh completado"

# Restaurar conf (enable.sh lo sobreescribe)
cat > /data/conf/serial-starter.d/dbus-serialbattery.conf << SERIAL_EOF2
service sbattery dbus-serialbattery
alias cgwacs sbattery
alias rs485 sbattery
alias default sbattery
SERIAL_EOF2

# ------------------------------------------------------------------------------
# 15. Reiniciar serial-starter y esperar servicio
# ------------------------------------------------------------------------------
echo ""
echo "--- Reiniciando servicios ---"
svc -t /service/serial-starter
sleep 5

echo "Esperando servicio dbus-serialbattery..."
SVC_UP=0
for i in $(seq 1 15); do
    if svstat /service/dbus-serialbattery.ttyUSB0 >/dev/null 2>&1; then
        ok "Servicio activo: $(svstat /service/dbus-serialbattery.ttyUSB0)"
        SVC_UP=1
        break
    fi
    sleep 2
done

if [ "$SVC_UP" = "0" ]; then
    warn "Servicio no detectado aun. Puede requerir reboot del Cerbo."
fi

# ------------------------------------------------------------------------------
# 16. Configurar BatteryService (apuntar al DeviceInstance correcto)
# ------------------------------------------------------------------------------
echo ""
echo "--- Configurando BatteryService activo ---"
echo "Esperando que el driver publique en dbus (hasta 60 segundos)..."
INSTANCE=""
for i in $(seq 1 20); do
    INSTANCE=$(dbus -y com.victronenergy.battery.ttyUSB0 /DeviceInstance GetValue 2>/dev/null || echo "")
    [ -n "$INSTANCE" ] && break
    sleep 3
done
if [ -n "$INSTANCE" ]; then
    dbus -y com.victronenergy.settings /Settings/SystemSetup/BatteryService SetValue "com.victronenergy.battery/${INSTANCE}" >/dev/null 2>&1
    # Actualizar config.ini con el DeviceInstance real
    sed -i "s/^DEVICE_INSTANCE_ID_BATTERY = .*/DEVICE_INSTANCE_ID_BATTERY = ${INSTANCE}/" /data/apps/dbus-serialbattery/config.ini
    ok "BatteryService configurado: com.victronenergy.battery/${INSTANCE}"
    sleep 3
    ACTIVE=$(dbus -y com.victronenergy.system /ActiveBatteryService GetValue 2>/dev/null || echo "")
    SOC=$(dbus -y com.victronenergy.battery.ttyUSB0 /Soc GetValue 2>/dev/null || echo "")
    ok "ActiveBatteryService: ${ACTIVE}"
    ok "SOC: ${SOC}%"
else
    warn "No se pudo leer DeviceInstance. Verificar manualmente con:"
    warn "  dbus -y com.victronenergy.battery.ttyUSB0 /DeviceInstance GetValue"
    warn "  dbus -y com.victronenergy.settings /Settings/SystemSetup/BatteryService SetValue 'com.victronenergy.battery/N'"
fi

# ------------------------------------------------------------------------------
# 17. Fin
# ------------------------------------------------------------------------------
echo ""
echo "Para monitorear en tiempo real:"
echo "  tail -f /var/log/dbus-serialbattery.ttyUSB0/current | tai64nlocal"
echo ""
echo "Para reiniciar el servicio:"
echo "  svc -t /service/dbus-serialbattery.ttyUSB0"
echo ""
echo "=============================================="
echo "  Instalacion completada"
echo "=============================================="
