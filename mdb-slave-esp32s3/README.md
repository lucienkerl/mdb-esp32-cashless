# ESP32 - MDB Cashless Device Implementation
This project aims to implement an MDB (Multi-Drop Bus) cashless device using an ESP32 microcontroller. The goal is to enable the ESP32 to interface with vending machines and other devices that support the MDB protocol, allowing for cashless transactions using modern payment methods such as mobile payments, contactless cards, or online accounts.

![MDB Cashless Device](mdb-slave-esp32s3_pcb_v3.jpg)

## ⚠️ Cellular (SIM7080G) board not plug-and-play

The modem driver in `main/modem.c` targets the LilyGo T-SIM7080G-S3 devkit
pinout (GPIO4/5 for the modem UART, GPIO41 for PWRKEY, I2C on GPIO15/7 for
an AXP2101 PMU), not the custom `kicad/mdb-slave-esp32s3-sim7080g` PCB.
That PCB's modem UART/PWRKEY are actually wired to GPIO17/18/14 (matching
this file's already-present but currently unused `PIN_SIM7080G_*`
defines), and — more importantly — **GPIO4/5 are wired to the MDB bus on
that PCB**, so `modem.c` as it stands today would claim pins that are
already in use. Flashing this firmware onto that board will not bring up
cellular connectivity as-is. See
`kicad/mdb-slave-esp32s3-sim7080g/README.md` for the full pin trace and
what reconciling the two would take.

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

Full write-up, including the frame format and the backend flow:
[`docs/integrations/rfid-card-reader.md`](../docs/integrations/rfid-card-reader.md).
