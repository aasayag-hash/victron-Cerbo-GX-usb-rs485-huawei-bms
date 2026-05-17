# Victron Cerbo-S GX + Huawei SmartLi ESM via USB-RS485

Driver e instalador para conectar baterías **Huawei SmartLi ESM-48xxx** directamente a un **Victron Cerbo-S GX** usando un adaptador USB-RS485, sin necesidad de Home Assistant ni ningún intermediario MQTT.

## Probado con

| Hardware | Detalle |
|----------|---------|
| Cerbo-S GX | Venus OS v3.x |
| Huawei ESM-48150B1 | 150 Ah, 48V, 16S LiFePO4 (×2) |
| Huawei ESM-48100B1 | 100 Ah, 48V, 16S LiFePO4 (×1) |
| Multiplus-II 48/5000 | VE.Bus ttyS3 |
| SmartSolar MPPT 150/60 | VE.Direct ttyS2 |
| Adaptador USB-RS485 | CH340 con aislación galvánica |

---

## Cómo funciona

El instalador `install_huawei_esm.sh` realiza todo el proceso en un solo comando ejecutado por SSH en el Cerbo:

1. **Auto-discovery**: escanea slaves Modbus 214–231 en el bus RS485, autentica cada batería con el handshake de 2 pasos requerido por Huawei, y detecta modelo y capacidad automáticamente
2. **Instala `dbus-serialbattery`** desde el repositorio oficial de mr-manuel
3. **Escribe el driver `huawei_esm.py`** con la configuración detectada
4. **Parchea** `dbus-serialbattery.py` y `dbushelper.py` para registrar el driver y manejar temperaturas `None`
5. **Configura serial-starter** para que el adaptador CH340 sea reconocido como servicio de batería
6. **Configura DVCC** apuntando el `BatteryService` al `DeviceInstance` correcto automáticamente

---

## Requisitos previos

### Hardware
- Adaptador **USB-RS485 con aislación galvánica** (requerido por el manual Huawei)
  - Recomendado: Waveshare USB-RS485-B o similar con chip CH340/FTDI
- Las baterías conectadas en **daisy-chain RS485** por sus puertos `COM_OUT` con cable RJ-45
- El último eslabón de la cadena conectado al adaptador USB-RS485
- Adaptador conectado al puerto USB del Cerbo-S GX

### Software
- Venus OS con **SSH habilitado**: Configuración → General → Acceso root → SSH on
- Conexión a internet en el Cerbo (para descargar dbus-serialbattery)
- Direcciones Modbus configuradas en las baterías con la **Huawei Battery Monitor App**:
  - Batería 1 → slave ID **214**
  - Batería 2 → slave ID **215**
  - Batería 3 → slave ID **216**
  - (rango válido: 214–231)

---

## Instalación

```bash
# 1. Copiar el instalador al Cerbo
scp install_huawei_esm.sh root@<IP_CERBO>:/tmp/

# 2. Conectarse por SSH
ssh root@<IP_CERBO>

# 3. Ejecutar
bash /tmp/install_huawei_esm.sh
```

El instalador es interactivo y guía paso a paso:

```
==============================================
  Huawei SmartLi ESM - Instalador Venus OS
==============================================

Puerto USB-RS485 [/dev/ttyUSB0]: 

--- Buscando baterias Huawei ESM en el bus RS485 ---
Escaneando slaves 214-231 (puede tardar hasta 60 segundos)...

Baterias encontradas:

  Slave 214: ESM-48150B1  150Ah  16S  50.66V  SOC=89%
  Slave 215: ESM-48150B1  150Ah  16S  50.64V  SOC=89%
  Slave 216: ESM-48100B1  100Ah  16S  50.61V  SOC=88%

[OK] 3 bateria(s) detectada(s)

Usar estas baterias detectadas? [S/n]:

--- Limites de carga/descarga ---
Corriente maxima de CARGA en A [12]: 
Corriente maxima de DESCARGA en A [60]: 
Voltaje maximo de carga en V [55.0]: 
```

---

## Qué publica el driver en Venus OS

| Path dbus | Descripción |
|-----------|-------------|
| `/Dc/0/Voltage` | Voltaje promedio de los packs online |
| `/Dc/0/Current` | Corriente total (suma de packs) |
| `/Soc` | SOC ponderado por capacidad |
| `/Soh` | SOH promedio |
| `/Info/MaxChargeVoltage` | CVL (configurable) |
| `/Info/MaxChargeCurrent` | CCL (configurable) |
| `/Info/MaxDischargeCurrent` | DCL (configurable) |
| `/Voltages/Cell1..N` | Voltaje promedio por celda (pack_voltage / cells_in_series) |
| `/System/Temperature1` | Temp promedio pack 1 = (Tmax+Tmin)/2 |
| `/System/Temperature2` | Temp promedio pack 2 |
| `/System/Temperature3` | Temp promedio pack 3 |

> **Nota:** Las Huawei ESM no exponen voltajes individuales de celda ni temperaturas por celda vía Modbus. Los valores de celda son aproximaciones calculadas dividiendo el voltaje del pack por `cells_in_series`.

---

## Protocolo Modbus Huawei ESM

### Parámetros de conexión

| Parámetro | Valor |
|-----------|-------|
| Baud rate | 9600 |
| Bits de datos | 8 |
| Paridad | N |
| Stop bits | 1 |
| Función | RTU half-duplex |

### Autenticación (obligatoria)

Las Huawei ESM requieren autenticación después de cada ciclo de energía o reconexión:

| Paso | Función Modbus | Registro | Descripción |
|------|---------------|----------|-------------|
| 1 | FC03 (Read) | `0x0106` | Leer 7 registros (handshake de desbloqueo) |
| 2 | FC10 (Write) | `0x1000` | Escribir fecha/hora actual (6 registros: año, mes, día, hora, min, seg) |

### Mapa de registros (lectura, FC03)

| Registro | Descripción | Escala | Tipo |
|----------|-------------|--------|------|
| `0x0000` | Voltaje del pack | × 0.01 V | uint16 |
| `0x0002` | Corriente | × 0.01 A (int16, complemento a 2 si > 32767) | int16 |
| `0x0003` | SOC | % | uint16 |
| `0x0004` | SOH | % | uint16 |
| `0x0005` | Temperatura máxima de celda | °C | uint16 |
| `0x0006` | Temperatura mínima de celda | °C | uint16 |
| `0x000A` | Status bitfield | — | uint16 |
| `0x0107` | Capacidad nominal | Ah | uint16 |

---

## Configuración generada (`config.ini`)

```ini
[DEFAULT]
BMS_TYPE = HuaweiEsm
MAX_BATTERY_CHARGE_CURRENT = 12
MAX_BATTERY_DISCHARGE_CURRENT = 60
CVCM_ENABLE = False
DEVICE_INSTANCE_ID_BATTERY = 3
```

- `CVCM_ENABLE = False`: desactiva la gestión de corriente por voltaje de celda individual, ya que las Huawei ESM no exponen ese dato
- `DEVICE_INSTANCE_ID_BATTERY`: fijado para que el `BatteryService` apunte siempre al mismo servicio entre reinicios

---

## Activar DVCC en Venus OS

Después de instalar, activar en la UI del Cerbo:

**Configuración → DVCC → Habilitar**

Con DVCC activo el SmartSolar y el Multiplus respetarán el CVL/CCL/DCL publicado por el driver.

---

## Monitoreo y diagnóstico

```bash
# Ver logs en tiempo real
tail -f /var/log/dbus-serialbattery.ttyUSB0/current | tai64nlocal

# Reiniciar el servicio del driver
svc -t /service/dbus-serialbattery.ttyUSB0

# Verificar datos en dbus
dbus -y com.victronenergy.battery.ttyUSB0 /Dc/0/Voltage GetValue
dbus -y com.victronenergy.battery.ttyUSB0 /Soc GetValue
dbus -y com.victronenergy.battery.ttyUSB0 /Info/MaxChargeVoltage GetValue

# Ver todos los servicios activos
dbus -y | grep victronenergy
```

Ejemplo de log normal con 3/3 packs online:
```
INFO:SerialBattery:Huawei ESM: 3/3 packs | V=50.66V Vcell=3.166V I=9.28A SOC=90% SOH=98% T1=22.0 T2=23.0 T3=23.5
```

---

## Solución de problemas

| Síntoma | Causa probable | Solución |
|---------|---------------|----------|
| `SOC = --` en pantalla principal | `BatteryService` apunta a `DeviceInstance` incorrecto | `dbus -y com.victronenergy.battery.ttyUSB0 /DeviceInstance GetValue` y actualizar con `SetValue` |
| No se crea `/service/dbus-serialbattery.ttyUSB0` | serial-starter no reconoce el adaptador CH340 | Verificar `/data/conf/serial-starter.d/dbus-serialbattery.conf` contiene `alias cgwacs sbattery` |
| SmartSolar en "BMS controlled: No" | DVCC desactivado | Activar en Configuración → DVCC |
| Driver tarda ~4 minutos en arrancar | `BMS_TYPE` no configurado (escanea todos los BMS) | Verificar que `config.ini` tenga `BMS_TYPE = HuaweiEsm` |
| Pack no autenticado tras reconexión | Normal — re-autentica automáticamente en el siguiente ciclo | Esperar un ciclo de polling (~5s) |

---

## Estructura del repositorio

```
├── install_huawei_esm.sh     # Instalador completo (ejecutar en el Cerbo)
└── README.md                 # Este archivo
```

El driver `huawei_esm.py` es **generado por el instalador** con los parámetros detectados (slaves, capacidades, CVL). No se distribuye como archivo estático porque `PACK_CONFIG` y `max_battery_voltage` se adaptan a cada instalación.

---

## Referencias

- [dbus-serialbattery (mr-manuel)](https://github.com/mr-manuel/venus-os_dbus-serialbattery) — framework base
- [Huawei Battery Monitor (williamsioSapo)](https://github.com/williamsioSapo/Huawei_Battery_monitor) — mapa de registros Modbus
- [Venus OS overlay-fs](https://github.com/victronenergy/venus-os_overlay-fs) — requerido por dbus-serialbattery v2

---

## Licencia

MIT
