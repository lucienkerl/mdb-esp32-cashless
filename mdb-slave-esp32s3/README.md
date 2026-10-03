# ESP32 - MDB Cashless Device Implementation
This project aims to implement an MDB (Multi-Drop Bus) cashless device using an ESP32 microcontroller. The goal is to enable the ESP32 to interface with vending machines and other devices that support the MDB protocol, allowing for cashless transactions using modern payment methods such as mobile payments, contactless cards, or online accounts.

![MDB Cashless Device](mdb-slave-esp32s3_pcb_v3.jpg)

## Supported boards — single firmware source

This is now the **only** slave firmware tree. The original PCB and the
newer ESP32-S3-WROOM-1U PCB (`kicad/mdb_slave_esp32s3-wroom-1u/`) share the
same `main/mdb-slave-esp32s3.c`, gated at runtime by `detect_board_variant()`
so WROOM-1U-only peripherals never touch GPIOs that don't exist on the
original board. A previous `mdb-slave-esp32s3-wroom-1u/` directory held a
full duplicate of this project while the new board was being brought up;
it has been folded back into this one.

**Not unified**: flash size / PSRAM / partition table. The WROOM-1U module
is 16MB flash + 2MB Quad-mode PSRAM with a custom `partitions.csv` (adds a
`dbglog` data partition); this tree's checked-in `sdkconfig` still targets
the original board's 4MB flash and the stock `partitions_two_ota_large.csv`
(no `dbglog` partition). That's a real hardware difference, not something
firmware can autodetect — see "Before first flash" below. `debug_log_init()`
fails safe if the `dbglog` partition is missing (logs an error, the feature
just stays inert), so building/flashing this tree unmodified for the
original board is safe; the local debug log simply won't be active on it
yet.

### Automatic board detection (GPIO3 strap)

GPIO8/9 (`PIN_DEX_RX`/`PIN_DEX_TX`) carry DEX/DDCMP telemetry on the
original board; WROOM-1U has no DEX reader hardware, so those GPIOs are
simply free/unused there. `detect_board_variant()` (top of `app_main`)
reads GPIO3 once at boot to tell the boards apart:

- **GPIO3 reads HIGH** (internal pull-up wins, pin left floating) →
  original board → DEX/UART1 init runs, relay/custom-input/1-Wire/GPIO1,2,
  6,15,16,17,18 stay untouched.
- **GPIO3 reads LOW** (external 10kΩ pull-down to GND, fitted on the
  WROOM-1U PCB) → WROOM-1U board → DEX/UART1 init is skipped, relay/
  custom-input/1-Wire drivers run instead.

### Pin mapping — WROOM-1U specific

Per the schematic's own IO legend (unlisted pins match the original
board unchanged):

| GPIO | Function | Firmware define | Status |
|---|---|---|---|
| 1 | Relay 1 (J2) | `PIN_RELAY_1` | driver done — output, MQTT config cmd `0x33` |
| 2 | Relay 2 (J3) | `PIN_RELAY_2` | driver done — output, MQTT config cmd `0x34` |
| 3 | Board-ID strap | `PIN_BOARD_ID` | see board detection above |
| 6 | Custom input 1 (J11) | `PIN_CUSTOM_INPUT1` | driver done — debounced, published on `/input` |
| 8, 9 | unused | `PIN_DEX_RX`/`PIN_DEX_TX` on original | DEX-only on original board, no DEX hardware on WROOM-1U |
| 15 | 1-Wire bus 1 (J4) | `PIN_ONEWIRE_1` | driver done — boot scan + 5min DS18B20 tracking |
| 16 | 1-Wire bus 2 (J5/J6) | `PIN_ONEWIRE_2` | driver done — boot scan + 5min DS18B20 tracking |
| 17 | Custom input 2 (J13) | `PIN_CUSTOM_INPUT2` | driver done — debounced, published on `/input` |
| 18 | Custom input 3 (J14) | `PIN_CUSTOM_INPUT3` | driver done — debounced, published on `/input` |
| 44 | RFID reader RX (J1 `RXD`) | `CONFIG_RFID_RX_GPIO_WROOM_1U` | serial RFID reader input — see "RFID card reader" below |
| 46, 47, 48 | free | — | unused on this PCB revision |

GPIO13 (`PIN_PULSE_1`, J8) exists only on the **original** board — the
pulse circuit has been desoldered on the WROOM-1U PCB revision, so this
pin is free/unused there. On the original board it's now a live input —
see "Pulse input" under "Board-specific drivers" below. The serial RFID
reader, which uses GPIO13 on the original board, moves to the J1 UART
header on WROOM-1U (GPIO44, see "RFID card reader on the pulse input").

WiFi-only board, confirmed no GPS/LTE-M/NB-IoT — `network.c`'s existing
"no modem → WiFi-only boot" path is used as-is, and `modem.c`/
`modem_https.c` stay fully inert via the existing `modem_probe()` fallback.

**Cellular (SIM7080G) board note**: `modem.c` drives the modem UART/PWRKEY
on GPIO18/17/14, the pins of the custom `kicad/mdb-slave-esp32s3-sim7080g`
PCB. On WROOM-1U those GPIOs carry custom inputs 2/3, so `app_main` calls
`network_disable_modem_probe()` before `network_init()` on that board: it
goes straight to the WiFi branch and the probe never touches GPIO17/18.

### Board-specific drivers (relay / custom input / 1-Wire / pulse / buzzer)

Relay, custom-input, and 1-Wire are gated behind `g_board_is_wroom_1u` so
none of them ever run on the original board; the pulse input is the
mirror image — gated on `!board_is_wroom_1u` so it only runs on the
original board, which is the only one with that circuit populated:

- **Relays** (`PIN_RELAY_1`/`PIN_RELAY_2`): plain digital outputs,
  initialised OFF at boot (`relay_init()`). Driven via the existing
  XOR-encrypted MQTT config command path — cmd `0x33` sets relay 1, `0x34`
  sets relay 2. Ignored with a warning log on the original board.
- **Custom inputs** (`PIN_CUSTOM_INPUT1/2/3`): `custom_input_task` polls
  all three every 100ms, debounces each transition over 50ms, and
  publishes `{channel, level, ts, prevHeldSec}` (QoS 1) to
  `/{company_id}/{device_id}/input` on every confirmed level change.
  Device-agnostic — interpreting events (door-open alarms, notification
  routing) is backend/app work.
- **Pulse input** (`PIN_PULSE_1`, original board only): legacy pre-MDB
  vending "Pulse" signaling — some older coin/bill mechanisms report
  credit as a train of edges instead of a serial protocol. `pulse_input_task`
  counts rising edges in hardware via the ESP32-S3 PCNT peripheral (not
  GPIO polling — pulse trains can be faster than a debounced poll loop
  would reliably catch), draining the counter every 200ms and publishing
  `{count, ts}` (QoS 1) to `/{company_id}/{device_id}/pulse` whenever the
  count is non-zero. **Deliberately not decoded into vend credit yet** —
  there's no confirmed pulse-value/timing spec for this connector, so
  this is raw telemetry only for now; converting counts into actual
  credit is follow-up work once the protocol is confirmed on hardware.
  **Off by default while the RFID reader uses GPIO13**: the serial RFID
  reader (see "RFID card reader on the pulse input" below) listens on the
  same pin by default (`CONFIG_RFID_RX_GPIO=13`), and PCNT would count
  its UART frames as pulses. The pulse task only starts when
  `CONFIG_RFID_READER_ENABLE` is off or the reader is moved to another
  GPIO.
- **Buzzer** (`PIN_BUZZER_PWR`): WROOM-1U's buzzer is an MLT-8530
  electro-magnetic transducer, which per its datasheet needs an
  oscillating drive at its 2700Hz resonant frequency (50% duty square
  wave) — a static DC level only produces a faint click as the diaphragm
  moves once, not the audible beep the code intends. On credit-received
  events (`BIT_EVT_BUZZER`), the original board keeps the old static
  1-second ON/OFF drive unchanged (its buzzer circuit isn't confirmed to
  be the same part); on WROOM-1U the same event now drives the pin via
  LEDC at 2700Hz/50% duty for 1 second instead.
- **1-Wire buses** (`PIN_ONEWIRE_1`/`PIN_ONEWIRE_2`): RMT-based bus scan
  via `espressif/onewire_bus` + `espressif/ds18b20`
  (`onewire_bus_scan_and_read()`), dispatched by ROM family code. DS18B20
  (family `0x28`) is read at boot; other families are logged as "no
  driver yet". Re-read every 5 minutes.

### Local debug log (relay / custom input / 1-Wire / NTC)

Offline-safe diagnostic buffer, separate from the sales queue
(`sale_queue.c`, unchanged). Implemented in `debug_log.c`/`.h`:

- **Storage**: a dedicated raw flash partition (`dbglog`, ~800KB — see
  `partitions.csv` on WROOM-1U) holding a ring of fixed 16-byte records,
  not NVS — per-key NVS overhead and page-relocation cost stop being
  worth it at this record count. Two small NVS counters track ring
  position across reboots (same role as `sale_queue.c`'s
  `K_HEAD`/`K_TAIL`).
- **What gets logged**: relay commands, every debounced custom-input
  transition, periodic NTC/DS18B20 readings, and non-zero pulse-input
  count windows (original board only).
- **NTC thermistor conversion**: TH1 is a Murata NCP18XH103F03RB (10kΩ
  @ 25°C, B25/50 = 3380K). Divider per the schematic (`kicad/mdb-slave-
  esp32s3`, TH1/R15): `+3V3 → R15 (10kΩ) → ADC7 node → TH1 → GND`.
  `ntc_mv_to_celsius()` inverts the divider then applies the
  single-B-constant NTC equation, using ADC curve-fitting calibration
  where supported.
- **Periodic tracking**: a 5-minute `esp_timer` re-reads the NTC (both
  board variants) and, on WROOM-1U only, both 1-Wire buses — each only
  logs when its reading has moved ≥0.5°C since the last logged value.
- **Publishing**: reuses the existing `/mdb-log` MQTT topic with an added
  `"type"` field (`relay`/`input`/`onewire`/`ntc`). A drain task publishes
  the oldest un-acked record once MQTT is connected, mirroring
  `sale_queue.c`'s drain loop.
- **Fails safe if unavailable**: `debug_log_init()` looks up the `dbglog`
  partition by label; if it's not present in the flashed partition table
  (true today for the original board's `sdkconfig`), it logs an error and
  every other `debug_log_*` call becomes a no-op — no crash.

## Before first flash — WROOM-1U

- `sdkconfig` (this tree, as checked in) still targets the **original**
  board: 4MB flash, stock `partitions_two_ota_large.csv`, no PSRAM. For a
  WROOM-1U board, before flashing: run `idf.py menuconfig` → **Serial
  Flasher Config** → flash size **16MB**; **Component config → ESP
  PSRAM** → enable, mode **Quad** (the WROOM-1U-N16R2's `ESP32-S3R2` chip
  is 2MB PSRAM in Quad SPI, not Octal — Octal is only on the R8/R8V/R16V
  variants); **Partition Table** → Custom, filename `partitions.csv`
  (already checked in) to get the `dbglog` partition.
- GPIO3 pull-down (board-ID strap): note pin **3 on the WROOM-1 module**
  is `EN`, not GPIO3 — GPIO3 is pin **15** on the module's own pin table.
  Fit a 10kΩ pull-down from GPIO3 (module pin 15) to GND.
- Relay / custom-input / 1-Wire drivers and the debug log are implemented
  but **not yet exercised on real WROOM-1U hardware** — the PCB bring-up
  was still in progress as of this consolidation. Confirm behavior on a
  real board before relying on them in production.

## RFID card reader on the pulse input

A serial RFID reader (F02DC and compatibles) can be wired to the board's
pulse input — reader TX to GPIO 13, plus GND and power — and turns the
machine into a prepaid-card reader. No hardware change: the pin is routed
through the GPIO matrix to UART0, which is free because the console runs
over USB-Serial-JTAG.

Presenting a card sends its serial to the backend, which answers with the
balance of that card's account as MDB credit; the vend that follows is
charged back to the account. Settings live under
`idf.py menuconfig` → **RFID card reader**; the driver is
`main/rfid_reader.c` with a host-side test in `test/rfid/run.sh`.

### On the ESP32-S3-WROOM-1U board

The WROOM-1U PCB has no pulse circuit, so the same reader goes on the
**`RXD` pin of the J1 UART header (GPIO 44)** instead — reader TX to `RXD`,
plus `GND` and `+3V3` from the same header. GPIO 44 is UART0's own RX pad,
and J1 is free at runtime because the board is flashed and logged over USB
(USB-Serial-JTAG), not over that UART. The firmware picks the pin at boot
from the GPIO3 board-ID strap: `CONFIG_RFID_RX_GPIO` (13) on the original
board, `CONFIG_RFID_RX_GPIO_WROOM_1U` (44 by default) on WROOM-1U. Driver,
frame format and backend flow are identical on both boards. A 5 V reader
still needs a divider on its TX line.

This was added at the request of a WROOM-1U board user, who had opened
their own PR to get the RFID reader working on this board.

Full write-up, including the frame format and the backend flow:
[`docs/integrations/rfid-card-reader.md`](../docs/integrations/rfid-card-reader.md).
