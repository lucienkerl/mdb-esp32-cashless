# RFID card reader on the pulse input (F02DC)

Prepaid card payment for a machine that already has the VMflow cashless
board in it. A serial RFID reader is wired to the board's **pulse input**;
presenting a card hands the machine the balance of that card's account as
MDB credit, and whatever the customer buys is deducted again.

No hardware change: the pulse input (GPIO 13, `PIN_PULSE_1`) is routed
through the ESP32-S3 GPIO matrix to a spare UART receiver.

---

## Wiring

| Reader | Board |
|--------|-------|
| TX (data out) | pulse input, GPIO 13 |
| GND | GND |
| VCC | 5 V / 12 V per the reader's own spec |

The reader only talks; nothing is ever sent to it, so its RX line can stay
unconnected.

UART allocation on the slave board — UART1 carries DEX telemetry, UART2 the
SIM7080G modem, and **UART0 is free** because the console runs over
USB-Serial-JTAG (`CONFIG_ESP_CONSOLE_USB_SERIAL_JTAG=y`). The reader takes
UART0. `rfid_reader.c` fails the build rather than the field if a
menuconfig change ever puts the console back on the same port.

---

## Frame format

9600 baud, 8 data bits, 1 stop bit, no parity.

```
0x02 | LEN | TYPE | CARD DATA … | XOR | 0x03
```

| Field | Meaning |
|-------|---------|
| `0x02` | frame header |
| `LEN` | frame length |
| `TYPE` | card type, 1 byte |
| `CARD DATA` | card serial number, MSB first |
| `XOR` | XOR of `LEN`, `TYPE` and every card-data byte |
| `0x03` | frame end |

The parser in `mdb-slave-esp32s3/main/rfid_reader.c` is delimiter-driven and
validated by the XOR byte rather than by trusting `LEN`, because vendors
disagree about what `LEN` counts (whole frame / payload / payload plus
checksum). A `0x03` that happens to fall inside the card data simply fails
the XOR check, and parsing continues to the real frame end.

The serial is reported as uppercase hex — `04A1B2C3` for the four bytes
`04 A1 B2 C3`.

## Duplicate suppression

These readers repeat the serial for as long as the card sits on the antenna,
typically every 100-500 ms. `rfid_reader.c` reports only the first sighting
and drops the rest; each repeat slides the suppression window forward
(`CONFIG_RFID_DEDUP_MS`, default 5000), so **one card presentation is exactly
one backend request** however long the card is held there. The card has to be
away for the length of the window before it counts as a new presentation.

When a card cannot be reported — the device is unprovisioned, MQTT is
offline, the publish fails — the suppression memory is cleared, so the
customer just presents the card again instead of waiting the window out.

## menuconfig

`idf.py menuconfig` → **RFID card reader**

| Option | Default | Notes |
|--------|---------|-------|
| `RFID_READER_ENABLE` | y | off leaves the pulse input untouched |
| `RFID_UART_PORT` | 0 | UART1/UART2 are taken |
| `RFID_RX_GPIO` | 13 | `PIN_PULSE_1` |
| `RFID_BAUD` | 9600 | F02DC ships at 9600 8N1 |
| `RFID_INVERT_RX` | n | for an inverting buffer/optocoupler in front of the pin |
| `RFID_DEDUP_MS` | 5000 | duplicate suppression window |

---

## Wire format to the backend

Card presentations are published to `/{company_id}/{device_id}/card` with
QoS 1. The 19-byte sale payload has no room for a card serial, so this topic
carries its own variable-length layout; the security envelope is the usual
one (passkey XOR, timestamp, sum checksum).

```
byte 0        cmd      0x25
byte 1        version  0x01
bytes 2-5     unix timestamp, big endian
byte 6        card type
byte 7        uid length N (1..16)
bytes 8..7+N  card serial, MSB first
byte 8+N      checksum = sum(bytes 0..7+N) & 0xFF
```

XOR covers bytes `1..8+N` with `passkey[(i - 1) % passkey.length]`.

Encoder: `mdb-slave-esp32s3.c::card_payload_encode`.
Decoder: `Docker/supabase/functions/mqtt-webhook/card-payload.ts`
(round-trip tested in `card-payload.test.ts`).

---

## Backend flow

1. The forwarder relays `/+/+/card` to `mqtt-webhook`.
2. `card_account_resolve(company, uid)` looks for an account **whose name
   contains the serial**, so `04A1B2C3` can be renamed to
   `Jane Doe (04A1B2C3)` without breaking the card. An unknown card gets a
   new account named after the serial, with a balance of 0.
3. The balance is delivered on the `/credit` topic — the same path
   `send-credit` uses — clamped to `[0, 655.35]`. The ceiling is the MDB
   credit field's uint16 of scaled cents; above it the amount would wrap
   around. A blocked (`is_active = false`) or empty account gets 0, which
   the firmware reads as "cancel the session".
4. `card_session_open` records which account is holding the machine's credit.
   Only one session per device is open at a time.
5. The vend arrives on the `/sale` topic as a normal **cashless** sale.
   After the sale row is inserted, `card_account_charge_vend` subtracts the
   price from that session's account, writes a `card_account_transactions`
   row and closes the session.

Sessions expire after 15 minutes; the firmware cancels an idle MDB session
after 60 s, so anything older is not a customer still standing at the
machine. Credit pushed from anywhere else (`send-credit`, Stripe, the app)
closes the open card session first, so the vend it pays for is never charged
back to whoever tapped last.

Charging is idempotent twice over: `card_account_transactions` has a unique
index on `sale_id`, and the RPC checks for an existing row before touching
the balance. A webhook replay therefore never double-charges.

### Tables

| Table | Purpose |
|-------|---------|
| `card_accounts` | `name`, `balance` (EUR), `is_active`, `last_seen_at` |
| `card_account_transactions` | append-only ledger; `topup` / `vend` / `adjustment` / `refund` |
| `card_sessions` | which account currently holds a machine's credit |

### RPCs

| Function | Caller |
|----------|--------|
| `card_account_resolve(company, uid)` | mqtt-webhook (service role) |
| `card_session_open(company, device, account, uid, credit)` | mqtt-webhook |
| `card_session_close(device, reason)` | mqtt-webhook, send-credit, `deliverCredit` |
| `card_account_charge_vend(device, amount, sale_id)` | mqtt-webhook |
| `card_account_topup(account, amount, description)` | frontend (admin) |

---

## Operating it

`/card-accounts` in the management app lists every account with its balance,
last use and status. Admins can create accounts up front, rename them (the
editor warns when a rename would drop the serial and orphan the card), block
a lost card, top up or correct a balance, and read the per-account ledger.

The usual first run is the other way round: present the card at the machine,
then rename the account that shows up and top it up.

### Diagnostics

The MDB diagnostics payload (`/mdb-log`, visible on the machine's Device
Health tab) gains an `rfid` block once a reader is attached:

```json
"rfid": { "ok": 128, "bad": 0, "cards": 37, "dup": 412 }
```

`ok` framed reads, `bad` frames dropped (line noise, a partial frame, an
overlong burst), `cards` presentations forwarded to the backend, `dup`
repeats suppressed. A healthy reader shows `dup` far above `cards` and `bad`
near zero. A `bad` count climbing in step with `ok` usually means a baud or
polarity mismatch — try `RFID_INVERT_RX`.
