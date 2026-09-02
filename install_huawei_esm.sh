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
echo "Escaneando slaves 214-231 (puede tardar unos minutos)..."
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

def crc_ok(frame):
    # El CRC viaja little-endian al final del frame y cubre todo lo anterior
    return len(frame) >= 4 and crc16(frame[:-2]) == struct.unpack("<H", frame[-2:])[0]

def read_regs(ser, slave, reg, count):
    ser.reset_input_buffer()
    ser.write(build_read(slave, reg, count))
    time.sleep(0.5)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    # Exigir tamano exacto, cabecera coherente y CRC: un frame truncado se
    # decodificaria como dato valido y haria detectar capacidades erroneas.
    if len(resp) != expected:
        return None
    if resp[0] != slave or resp[1] != 0x03 or resp[2] != count * 2:
        return None
    if not crc_ok(resp):
        return None
    return [struct.unpack(">H", resp[3+i*2:5+i*2])[0] for i in range(count)]

def authenticate(ser, slave):
    # Reintentos con espera progresiva: las ESM pueden estar en ahorro de
    # energia y no responder al primer intento (protocolo de wake-up Huawei).
    for attempt, delay in enumerate((0.4, 1.0, 2.0), start=1):
        if read_regs(ser, slave, 0x0106, 7) is not None:
            time.sleep(0.3)
            now = datetime.now()
            ser.reset_input_buffer()
            ser.write(build_write(slave, 0x1000,
                      [now.year, now.month, now.day, now.hour, now.minute, now.second]))
            time.sleep(0.5)
            ser.read(8)
            return True
        if attempt < 3:
            time.sleep(delay)
    return False

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
echo ""
echo "  IMPORTANTE: MAX_BATTERY_CHARGE_CURRENT es un TECHO ABSOLUTO, no un valor"
echo "  por defecto. El driver aplica min(DVCC, este valor), asi que si lo dejas"
echo "  bajo, subir la corriente en Settings -> DVCC NO tendra efecto."
echo ""
echo "  Recomendado: dejarlo alto (0.2C del banco) y regular el dia a dia desde"
echo "  la GUI en Settings -> DVCC -> Maximum charge current."
echo ""

# Techo sugerido: 0.2C del banco detectado (limite tipico de carga de las ESM)
CCL_SUGGESTED=$(python3 -c "print(int(round(${TOTAL_AH:-100} * 0.2)))" 2>/dev/null || echo 30)

read -p "Techo maximo de CARGA en A [${CCL_SUGGESTED}]: " CCL
read -p "Corriente maxima de DESCARGA en A [60]: "        DCL
read -p "Voltaje maximo de carga en V [55.0]: "           CVL
CCL=${CCL:-$CCL_SUGGESTED}
DCL=${DCL:-60}
CVL=${CVL:-55.0}

# ------------------------------------------------------------------------------
# 4b. Limite de corriente de carga por pack (registro 0x100D)
# ------------------------------------------------------------------------------
# El registro 0x100D de las Huawei ESM NO esta en amperios: es un coeficiente
# de C-rate con escala 0.001 ("Charge Limit Coef" / 充电限流点 en la doc oficial
# Huawei). Por eso el valor a escribir depende de la capacidad de cada pack:
#
#     valor = round(amperios / capacidad_Ah * 1000)
#
# Ejemplo para 30 A: pack de 150Ah -> 200 ; pack de 100Ah -> 300
#
# Es un registro de configuracion PERSISTENTE en el BMS. Por eso se lee primero
# el valor actual de cada pack y se muestra su interpretacion, para confirmar
# que la escala es correcta antes de escribir nada.
#
# NO se tocan 0x101B (Default Charge Limit Coef, valor de fabrica) ni 0x127E
# (bloque de umbrales de proteccion de sobrecorriente).
echo ""
echo "--- Limite de corriente de carga por bateria (registro 0x100D) ---"
echo ""
info "Leyendo configuracion actual de 0x100D en cada bateria..."
echo ""

CCL_READ=$(python3 - "$TTY" "$PACK_CONFIG" << 'PYEOF'
import sys, struct, time, serial, ast
from datetime import datetime

port, packs = sys.argv[1], ast.literal_eval(sys.argv[2])
REG_CHG_LIMIT = 0x100D

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc

def build_read(slave, reg, count):
    f = struct.pack(">BBHH", slave, 0x03, reg, count)
    return f + struct.pack("<H", crc16(f))

def build_write(slave, reg, values):
    n = len(values)
    f = struct.pack(">BBHHB", slave, 0x10, reg, n, n * 2)
    for v in values:
        f += struct.pack(">H", v)
    return f + struct.pack("<H", crc16(f))

def crc_ok(frame):
    # El CRC viaja little-endian al final del frame y cubre todo lo anterior
    return len(frame) >= 4 and crc16(frame[:-2]) == struct.unpack("<H", frame[-2:])[0]

def read_regs(ser, slave, reg, count):
    ser.reset_input_buffer()
    ser.write(build_read(slave, reg, count))
    time.sleep(0.5)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    # Un frame truncado de >=5 bytes se decodificaria como dato valido si solo
    # se mirase la longitud minima: exigir tamano exacto, cabecera y CRC.
    if len(resp) != expected:
        return None
    if resp[0] != slave or resp[1] != 0x03 or resp[2] != count * 2:
        return None
    if not crc_ok(resp):
        return None
    return [struct.unpack(">H", resp[3+i*2:5+i*2])[0] for i in range(count)]

def authenticate(ser, slave):
    if read_regs(ser, slave, 0x0106, 7) is None:
        return False
    time.sleep(0.3)
    now = datetime.now()
    ser.reset_input_buffer()
    ser.write(build_write(slave, 0x1000,
              [now.year, now.month, now.day, now.hour, now.minute, now.second]))
    time.sleep(0.5)
    ser.read(8)
    return True

try:
    ser = serial.Serial(port, baudrate=9600, bytesize=8, parity="N", stopbits=1, timeout=1)
except Exception as e:
    sys.stderr.write("Error abriendo %s: %s\n" % (port, e))
    sys.exit(1)

for slave, cap, model, cells in packs:
    if not authenticate(ser, slave):
        print("%d|%s|%d|ERR|auth" % (slave, model, cap))
        continue
    vals = read_regs(ser, slave, REG_CHG_LIMIT, 1)
    if vals is None:
        print("%d|%s|%d|ERR|read" % (slave, model, cap))
        continue
    raw = vals[0]
    amps_now = raw * 0.001 * cap                      # interpretacion C-rate
    print("%d|%s|%d|%d|%.1f" % (slave, model, cap, raw, amps_now))
    time.sleep(0.2)

ser.close()
PYEOF
)

if [ -z "$CCL_READ" ]; then
    warn "No se pudo leer 0x100D de ninguna bateria."
    warn "Se omite el ajuste. El control de carga queda a cargo de DVCC."
else
    # --- Configuracion actual de las baterias ---
    echo "  Configuracion actual:"
    echo ""
    printf "  %-7s %-14s %-8s %-10s %s\n" "Slave" "Modelo" "Cap" "0x100D" "Limite carga"
    echo "  --------------------------------------------------------------"
    CCL_ERRORS=0
    CCL_OK_COUNT=0
    while IFS='|' read -r s model cap raw amps; do
        [ -z "$s" ] && continue
        if [ "$raw" = "ERR" ]; then
            printf "  %-7s %-14s %-8s %s\n" "$s" "$model" "${cap}Ah" "ERROR ($amps)"
            CCL_ERRORS=$((CCL_ERRORS + 1))
        else
            printf "  %-7s %-14s %-8s %-10s %s\n" "$s" "$model" "${cap}Ah" "$raw" "${amps}A"
            CCL_OK_COUNT=$((CCL_OK_COUNT + 1))
        fi
    done <<< "$CCL_READ"
    echo ""

    if [ "$CCL_ERRORS" -gt 0 ]; then
        warn "$CCL_ERRORS bateria(s) no respondieron a la lectura."
    fi

    echo "  La columna 'Limite carga' interpreta 0x100D como C-rate x 0.001"
    echo "  (0x100D = 'Charge Limit Coef' en la documentacion oficial Huawei)."
    echo "  Si esos amperios NO son coherentes con las baterias, la escala es"
    echo "  distinta: dejar el valor en 0 para no modificar nada."
    echo ""

    if [ "$CCL_OK_COUNT" -eq 0 ]; then
        warn "Ninguna bateria respondio. Se omite el ajuste."
    else
        # --- Valor unico para todas las baterias ---
        read -p "Corriente de carga a asignar a TODAS las baterias en A [0 = no cambiar]: " PACK_CCL_A
        PACK_CCL_A=${PACK_CCL_A:-0}

        if ! echo "$PACK_CCL_A" | grep -qE '^[0-9]+([.][0-9]+)?$'; then
            warn "Valor invalido '$PACK_CCL_A'. Se omite el ajuste."
            PACK_CCL_A=0
        fi
    fi

    CCL_POSITIVE=0
    if [ "${CCL_OK_COUNT:-0}" -gt 0 ]; then
        CCL_POSITIVE=$(python3 -c "print(1 if float('${PACK_CCL_A:-0}') > 0 else 0)" 2>/dev/null)
        if [ -z "$CCL_POSITIVE" ]; then
            warn "No se pudo evaluar el valor ingresado ('$PACK_CCL_A'). Se omite el ajuste."
            CCL_POSITIVE=0
        fi
    fi

    if [ "$CCL_POSITIVE" = "1" ]; then
        # Cada pack necesita un valor crudo distinto porque 0x100D es C-rate,
        # relativo a la capacidad: valor = round(A / capacidad_Ah * 1000)
        echo ""
        echo "  Cambios a aplicar (${PACK_CCL_A}A en todas):"
        echo ""
        printf "  %-7s %-14s %-8s %-14s %s\n" "Slave" "Modelo" "Cap" "0x100D actual" "-> nuevo"
        echo "  --------------------------------------------------------------------"
        CCL_WRITE_PLAN=""
        while IFS='|' read -r s model cap raw amps; do
            [ -z "$s" ] && continue
            [ "$raw" = "ERR" ] && continue
            tgt=$(python3 -c "print(int(round($PACK_CCL_A / $cap * 1000)))" 2>/dev/null)
            if ! echo "$tgt" | grep -qE '^[0-9]+$' || [ "$tgt" -lt 1 ] || [ "$tgt" -gt 65535 ]; then
                printf "  %-7s %-14s %-8s %s\n" \
                       "$s" "$model" "${cap}Ah" "OMITIDA (valor fuera de rango)"
                continue
            fi
            printf "  %-7s %-14s %-8s %-14s %s\n" \
                   "$s" "$model" "${cap}Ah" "$raw (${amps}A)" "$tgt (= ${PACK_CCL_A}A)"
            CCL_WRITE_PLAN+="${s}|${model}|${cap}|${raw}|${amps}|${tgt}"$'\n'
        done <<< "$CCL_READ"
        echo ""
        echo "  Nota: el valor crudo difiere entre baterias de distinta capacidad"
        echo "  porque 0x100D es un coeficiente C-rate, no amperios."
        echo ""
        warn "0x100D es configuracion PERSISTENTE del BMS de cada bateria."
        echo ""

        if [ -z "$CCL_WRITE_PLAN" ]; then
            warn "Ninguna bateria quedo con un valor valido. Se omite el ajuste."
            CCL_CONFIRM=N
        else
            read -p "Confirmar la escritura? [s/N]: " CCL_CONFIRM
            CCL_CONFIRM=${CCL_CONFIRM:-N}
        fi

        if [[ "$CCL_CONFIRM" =~ ^[Ss]$ ]]; then
            echo ""
            info "Escribiendo 0x100D en cada bateria..."
            python3 - "$TTY" "$CCL_WRITE_PLAN" << 'PYEOF'
import sys, struct, time, serial
from datetime import datetime

port = sys.argv[1]
rows = [l.split("|") for l in sys.argv[2].strip().splitlines() if l.strip()]
REG_CHG_LIMIT = 0x100D

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc

def build_read(slave, reg, count):
    f = struct.pack(">BBHH", slave, 0x03, reg, count)
    return f + struct.pack("<H", crc16(f))

def build_write(slave, reg, values):
    n = len(values)
    f = struct.pack(">BBHHB", slave, 0x10, reg, n, n * 2)
    for v in values:
        f += struct.pack(">H", v)
    return f + struct.pack("<H", crc16(f))

def crc_ok(frame):
    # El CRC viaja little-endian al final del frame y cubre todo lo anterior
    return len(frame) >= 4 and crc16(frame[:-2]) == struct.unpack("<H", frame[-2:])[0]

def read_regs(ser, slave, reg, count):
    ser.reset_input_buffer()
    ser.write(build_read(slave, reg, count))
    time.sleep(0.5)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    # Un frame truncado de >=5 bytes se decodificaria como dato valido si solo
    # se mirase la longitud minima: exigir tamano exacto, cabecera y CRC.
    if len(resp) != expected:
        return None
    if resp[0] != slave or resp[1] != 0x03 or resp[2] != count * 2:
        return None
    if not crc_ok(resp):
        return None
    return [struct.unpack(">H", resp[3+i*2:5+i*2])[0] for i in range(count)]

def authenticate(ser, slave):
    if read_regs(ser, slave, 0x0106, 7) is None:
        return False
    time.sleep(0.3)
    now = datetime.now()
    ser.reset_input_buffer()
    ser.write(build_write(slave, 0x1000,
              [now.year, now.month, now.day, now.hour, now.minute, now.second]))
    time.sleep(0.5)
    ser.read(8)
    return True

ser = serial.Serial(port, baudrate=9600, bytesize=8, parity="N", stopbits=1, timeout=1)

for row in rows:
    if len(row) < 6 or row[3] == "ERR":
        continue
    slave, model, cap, raw, amps, tgt = int(row[0]), row[1], int(row[2]), int(row[3]), row[4], int(row[5])

    if not authenticate(ser, slave):
        sys.stderr.write("  [ERR] slave %d: auth fallo, no se escribe\n" % slave)
        continue

    ser.reset_input_buffer()
    ser.write(build_write(slave, REG_CHG_LIMIT, [tgt]))
    time.sleep(0.5)
    resp = ser.read(8)
    # El eco valido de FC10 son exactamente 8 bytes: slave, 0x10, addr(2),
    # cantidad(2), crc(2). Un frame corto o con CRC malo NO es una confirmacion.
    if len(resp) != 8 or resp[0] != slave or resp[1] != 0x10 or not crc_ok(resp):
        if len(resp) >= 2 and resp[1] & 0x80:
            code = resp[2] if len(resp) > 2 else 0
            sys.stderr.write("  [ERR] slave %d (%s): la bateria rechazo la escritura "
                             "(excepcion Modbus 0x%02X)\n" % (slave, model, code))
        else:
            sys.stderr.write("  [ERR] slave %d (%s): sin confirmacion valida de la escritura "
                             "(%d bytes)\n" % (slave, model, len(resp)))
        continue

    time.sleep(0.3)
    back = read_regs(ser, slave, REG_CHG_LIMIT, 1)
    if back is None:
        sys.stderr.write("  [WARN] slave %d: escrito pero no se pudo releer\n" % slave)
    elif back[0] == tgt:
        sys.stderr.write("  [OK] slave %d (%s): 0x100D = %d (= %.1fA sobre %dAh)\n"
                         % (slave, model, tgt, tgt * 0.001 * cap, cap))
    else:
        sys.stderr.write("  [WARN] slave %d: se escribio %d pero la bateria reporta %d\n"
                         % (slave, tgt, back[0]))
    time.sleep(0.2)

ser.close()
PYEOF
            echo ""
            ok "Escritura de 0x100D finalizada."
        else
            warn "Escritura de 0x100D omitida. Las baterias quedan como estaban."
        fi
    else
        info "0x100D sin cambios. El control de carga queda a cargo de DVCC."
    fi
fi

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
from datetime import datetime
from battery import Battery, Cell
from utils import logger, open_serial_port

DRIVER_VERSION = "1.6.0"

# dbus path written by Venus OS GUI: Settings → DVCC → Maximum charge current
_DVCC_CCL_PATH = ("com.victronenergy.settings", "/Settings/SystemSetup/MaxChargeCurrent")

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


def _crc_ok(frame):
    """El CRC viaja little-endian al final del frame y cubre todo lo anterior."""
    return len(frame) >= 4 and _crc16(frame[:-2]) == struct.unpack("<H", frame[-2:])[0]


def _modbus_read(ser, slave, reg, count):
    ser.reset_input_buffer()
    ser.write(_build_read(slave, reg, count))
    time.sleep(0.4)
    expected = 3 + count * 2 + 2
    resp = ser.read(expected)
    # Un frame truncado o desalineado de >=5 bytes se decodificaria como dato
    # valido si solo se mirase la longitud minima. Las ESM producen frames
    # corruptos esporadicos en el bus RS485 que, sin esta validacion, se
    # publicaban como picos de tension irreales (ej. 56V con I=0.00A).
    if len(resp) != expected:
        return None
    if resp[0] != slave or resp[1] != 0x03 or resp[2] != count * 2:
        return None
    if not _crc_ok(resp):
        return None
    return [struct.unpack(">H", resp[3 + i*2: 5 + i*2])[0] for i in range(count)]


def _modbus_write(ser, slave, reg, values):
    ser.reset_input_buffer()
    ser.write(_build_write_multiple(slave, reg, values))
    time.sleep(0.5)
    resp = ser.read(8)
    # El eco valido de FC10 son exactamente 8 bytes: slave, 0x10, addr(2),
    # cantidad(2), crc(2). Un frame corto o con CRC malo NO es confirmacion.
    return (len(resp) == 8 and resp[0] == slave
            and resp[1] == 0x10 and _crc_ok(resp))


# Las ESM entran en modo de ahorro de energia y no responden al primer intento.
# El protocolo de wake-up de Huawei recomienda reintentar con espera progresiva.
# Se usan esperas cortas porque el ciclo de polling es de ~5s y el bus RS485 es
# compartido por todos los packs: un backoff largo bloquearia a los demas.
_AUTH_RETRY_DELAYS = (0.4, 1.0, 2.0)


def _authenticate_once(ser, slave_id):
    """Un intento del handshake de 2 pasos. True si ambos pasos responden."""
    if _modbus_read(ser, slave_id, REG_UNLOCK, 7) is None:
        return False
    time.sleep(0.3)
    now = datetime.now()
    ok = _modbus_write(ser, slave_id, REG_DATETIME,
                       [now.year, now.month, now.day, now.hour, now.minute, now.second])
    time.sleep(0.5)
    return ok


def _authenticate(ser, slave_id, model):
    for attempt, delay in enumerate(_AUTH_RETRY_DELAYS, start=1):
        if _authenticate_once(ser, slave_id):
            if attempt > 1:
                logger.info("Huawei ESM slave %d (%s): authenticated OK "
                            "(intento %d/%d)", slave_id, model,
                            attempt, len(_AUTH_RETRY_DELAYS))
            else:
                logger.info("Huawei ESM slave %d (%s): authenticated OK",
                            slave_id, model)
            return True
        # No esperar despues del ultimo intento fallido
        if attempt < len(_AUTH_RETRY_DELAYS):
            logger.debug("Huawei ESM slave %d: auth intento %d fallo, "
                         "reintentando en %.1fs", slave_id, attempt, delay)
            time.sleep(delay)

    logger.warning("Huawei ESM slave %d (%s): auth fallo tras %d intentos",
                   slave_id, model, len(_AUTH_RETRY_DELAYS))
    return False


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

        # dbus proxy for DVCC CCL setting — created once, reused every poll cycle
        self._dvcc_ccl_obj = None
        try:
            import dbus as _dbus
            _bus = _dbus.SystemBus()
            self._dvcc_ccl_obj = _bus.get_object(_DVCC_CCL_PATH[0], _DVCC_CCL_PATH[1])
        except Exception:
            pass

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

        # Read CCL from Venus OS GUI: Settings → DVCC → Maximum charge current
        # -1 means "no limit set by user" — keep driver's existing value in that case
        if self._dvcc_ccl_obj is not None:
            try:
                _val = float(self._dvcc_ccl_obj.GetValue(
                    dbus_interface="com.victronenergy.BusItem"
                ))
                if _val >= 0:
                    self.max_battery_charge_current = _val
            except Exception:
                pass

        ccl = self.max_battery_charge_current

        logger.info(
            "Huawei ESM: %d/%d packs | V=%.2fV Vcell=%.3fV I=%.2fA SOC=%.0f%% SOH=%.0f%% CCL=%s T1=%s T2=%s T3=%s",
            len(online), len(self.packs),
            self.voltage,
            sum(p.cell_voltage_avg for p in online) / len(online),
            self.current, self.soc, self.soh,
            ("%.0fA" % ccl) if ccl is not None else "N/A",
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
# El driver lee /data/apps/...; /data/etc/... es una copia que conviene mantener
# sincronizada para no diagnosticar sobre el archivo equivocado.
# El driver lee /data/apps/...; /data/etc/... es una copia que se mantiene
# sincronizada para no diagnosticar sobre el archivo equivocado.
CFG_PRIMARY="/data/apps/dbus-serialbattery"
CFG_PRIMARY_OK=0

for CFG_DIR in "$CFG_PRIMARY" /data/etc/dbus-serialbattery; do
    if ! mkdir -p "$CFG_DIR" 2>/dev/null; then
        warn "No se pudo crear $CFG_DIR"
        continue
    fi
    # Verificar la escritura: un 'cat >' fallido (FS lleno o de solo lectura)
    # no aborta el script por si solo y dejaria un config.ini vacio o ausente.
    if ! cat > "$CFG_DIR/config.ini" << CONFIG_EOF
[DEFAULT]
BMS_TYPE = HuaweiEsm
MAX_BATTERY_CHARGE_CURRENT = ${CCL}
MAX_BATTERY_DISCHARGE_CURRENT = ${DCL}
CVCM_ENABLE = False
CONFIG_EOF
    then
        warn "Fallo la escritura de $CFG_DIR/config.ini"
        continue
    fi
    if ! grep -q '^BMS_TYPE = HuaweiEsm' "$CFG_DIR/config.ini" 2>/dev/null; then
        warn "$CFG_DIR/config.ini quedo incompleto"
        continue
    fi
    info "config.ini escrito en $CFG_DIR"
    [ "$CFG_DIR" = "$CFG_PRIMARY" ] && CFG_PRIMARY_OK=1
done

# Sin config.ini en la ruta primaria el driver arranca sin BMS_TYPE y tarda
# minutos escaneando todos los BMS, o no levanta el driver correcto. Que la
# copia de /data/etc se haya escrito no sirve de nada por si sola.
[ "$CFG_PRIMARY_OK" = "1" ] || err "No se pudo escribir $CFG_PRIMARY/config.ini (ruta que el driver lee)."
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
# 17. Configurar DVCC: habilitar y fijar CCL desde el valor ingresado
# ------------------------------------------------------------------------------
echo ""
echo "--- Configurando DVCC ---"

# Habilitar DVCC
if dbus -y com.victronenergy.settings /Settings/Services/Bol SetValue 1 >/dev/null 2>&1; then
    ok "DVCC habilitado"
else
    warn "No se pudo habilitar DVCC — habilitarlo manualmente en Settings → DVCC"
fi

# Activar límite de corriente de carga y fijar el CCL ingresado por el usuario
if dbus -y com.victronenergy.settings /Settings/SystemSetup/MaxChargeCurrent SetValue "${CCL}" >/dev/null 2>&1; then
    ok "Maximum charge current fijado en ${CCL}A (editable en Settings → DVCC)"
else
    warn "No se pudo fijar MaxChargeCurrent — ajustarlo manualmente en Settings → DVCC"
fi

# SVS y STS activados
SVS_OK=true
STS_OK=true
dbus -y com.victronenergy.settings /Settings/SystemSetup/SharedVoltageSense SetValue 1 >/dev/null 2>&1    || SVS_OK=false
dbus -y com.victronenergy.settings /Settings/SystemSetup/SharedTemperatureSense SetValue 1 >/dev/null 2>&1 || STS_OK=false
if $SVS_OK && $STS_OK; then
    ok "SVS y STS habilitados"
else
    warn "SVS o STS no se pudieron habilitar — verificar en Settings → DVCC"
fi

# ------------------------------------------------------------------------------
# 18. Fin
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
