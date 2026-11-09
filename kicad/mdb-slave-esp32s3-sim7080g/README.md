# mdb-slave-esp32s3-sim7080g — pin mapping & firmware compatibility

Custom PCB variant of `mdb-slave-esp32s3` adding an onboard SIM7080G
(GPS/LTE-M/NB-IoT) modem — see `kicad/README.md` for the board photo.

## Confirmed pin mapping (traced from `mdb-slave-esp32s3-sim7080g.kicad_pcb` netlist)

| GPIO | Net | Function |
|---|---|---|
| 4 | `/io4` | MDB bus (bridged to `/mdb_communications_common` — same role as the base board's `PIN_MDB_RX`) |
| 5 | `/io5` | MDB bus (bridged to `/mdb_communications_common` — same role as `PIN_MDB_TX`) |
| 14 | `/io14` → R (base) → Q2 | SIM7080G PWRKEY, via an inverting NPN driver (Q2: base from GPIO14 through a resistor, emitter to GND, collector to `/pwrkey`) — GPIO high → Q2 conducts → PWRKEY pulled low ("press"), same inverted-polarity convention as `MODEM_PWRKEY_INVERTED` in `modem.c` |
| 17 | `/io17` → Q1 → `/sim_uart1_rx` | ESP TX → SIM7080G UART1_RXD, via level-shift transistor Q1 |
| 18 | `/io18` → Q3 → `/sim_uart1_tx` | SIM7080G UART1_TXD → ESP RX, via level-shift transistor Q3 |

No AXP2101 (or any other PMU) is present on this board — modem power is
gated purely by the PWRKEY drive above. SIM7080G UART1 RTS/CTS/DCD/DTR/RI
are all left unconnected (2-wire UART only).

## Firmware status: supported

`main/modem.c` uses exactly this pinout by default (RX 18, TX 17, PWRKEY
14, `MODEM_PWRKEY_INVERTED` = 1) and needs no PMU. (An earlier revision of
this file described a LilyGo-devkit pinout in `modem.c`; that is gone.)

The WROOM-1U board has no modem of its own; its optional plug-in LTE module
([`../lte-addon-sim7080g/`](../lte-addon-sim7080g/)) reuses this board's
modem circuit on GPIO39/40/41 and is selected at boot via `modem_set_pins()`.
