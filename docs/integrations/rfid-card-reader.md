# RFID card reader (F02DC)

Prepaid card payment for a machine that already has the VMflow cashless
board in it. A serial RFID reader is wired to the board's pulse pin
(GPIO 13, `PIN_PULSE_1`); presenting a card hands the machine the balance of
that card's account as MDB credit, and whatever the customer buys is
deducted again.

No added silicon: GPIO 13 is routed through the ESP32-S3 GPIO matrix to a
spare UART receiver. But the reader does **not** go on the Pulse connector —
read the wiring section before soldering anything.

---

## Wiring

**Not the Pulse connector.** On both PCBs — `J3` on `mdb-slave-esp32s3`,
`J7` on `mdb-slave-esp32s3-sim7080g` — the three-pin Pulse connector is a
pulse *output*: GND, `vin`, and the collector of Q7, an MMBT3904 whose base
GPIO 13 drives through R27 (4k7). A reader's TX wired there talks to a
transistor collector and nothing else; the SoC never sees a byte and the
`rx` counter below stays at 0 for ever.

The reader's TX has to reach GPIO 13 itself:

| Board | Where GPIO 13 is reachable |
|-------|----------------------------|
| `mdb-slave-esp32s3` | `io13` on the J4 2×11 expansion header, between `io12` and `io14` |
| `mdb-slave-esp32s3-sim7080g` | not broken out — the GPIO-13 side of the R27 pad, or a free pin |

| Reader | Board |
|--------|-------|
| TX (data out) | `io13` on the expansion header (**not** the Pulse connector) |
| GND | GND — on the header, or the Pulse connector's GND pin |
| VCC | 5 V / 12 V per the reader's own spec; the header carries `+3V3` and `vin` |

The reader only talks; nothing is ever sent to it, so its RX line can stay
unconnected.

Two electrical caveats on GPIO 13, both because R27 hangs off it:

- The reader's output must be **push-pull**, not open-collector. The pin's
  internal pull-up cannot hold the line high by itself: through R27 into
  Q7's base-emitter drop, an undriven line parks around 0.9 V, which the
  UART reads as a permanent low — a break condition, not an idle line. A
  push-pull driver overcomes it easily; R27 costs it about half a
  milliamp.
- A **5 V** reader needs a divider. R27 is in series with the transistor
  base, not with the pin — it loads GPIO 13, it does not protect it.

Any free GPIO does the job just as well, and without the transistor:
set *RFID card reader → RX GPIO* in `idf.py menuconfig`
(`CONFIG_RFID_RX_GPIO`). On `mdb-slave-esp32s3`, `io1`, `io2` and `io6` are
unused and sit on the same J4 header.

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
"rfid": { "ok": 128, "bad": 0, "cards": 37, "dup": 412, "rx": 5312 }
```

`ok` framed reads, `bad` frames dropped (line noise, a partial frame, an
overlong burst), `cards` presentations forwarded to the backend, `dup`
repeats suppressed, `rx` raw bytes read off the line. A healthy reader shows
`dup` far above `cards` and `bad` near zero. The machine's MDB diagnostics
card in the management app shows the same numbers, so a reader can be
checked without a serial cable at the machine.

`rx` is the one that separates the two ways a reader goes quiet, because
bytes arriving before the first `0x02` are discarded without touching any
other counter:

| Counters | Meaning |
|----------|---------|
| `rx` stays 0 while a card is presented | The reader is not talking to the board at all: wiring, power, or the wrong GPIO |
| `rx` climbs, `ok` stays 0 | The reader talks a dialect the parser rejects: baud rate, inverted line, or a different frame format |
| `bad` climbs in step with `ok` | Marginal signal — a baud or polarity mismatch; try `RFID_INVERT_RX` |

In the second case the firmware also logs the bytes themselves, once every
10 s so a mismatched reader cannot flood the console:

```
W rfid: 12 bytes, no valid frame: 30 30 30 34 41 31 42 32 43 33 0D 0A — check baud rate, ...
```

That example is an ASCII-output reader (`0004A1B2C3\r\n`) rather than the
binary framing this driver expects — visible at a glance, which is the
point.

---

## Troubleshooting

The chain is device → broker → forwarder → `mqtt-webhook` → database →
broker → device. Bisect it in that order; each stage leaves its own trace.

| Stage | How to see it | What "working" looks like |
|-------|---------------|---------------------------|
| Reader → firmware | `idf.py monitor`, or the `rfid` counters in `/mdb-log` | `cards` goes up once per presentation |
| Firmware → broker | `mosquitto_sub -t '/+/+/card' -u admin -P "$MQTT_ADMIN_PASS"` | one message per presentation |
| Broker → forwarder | `docker compose logs -f forwarder` | a line for the `/card` topic |
| Forwarder → webhook | `docker compose logs -f functions` | no 4xx/5xx for `mqtt-webhook` |
| Webhook → database | `card_accounts` in Studio | a row named after the serial, `last_seen_at` fresh |
| Webhook → device | `mosquitto_sub -t '/+/+/credit' -u admin -P "$MQTT_ADMIN_PASS"` | a 19-byte message right after the card read |

A row appearing in `card_accounts` while nothing shows up on `/credit`
narrows the fault to the last hop: the webhook resolved the card and opened
the session, then failed to publish. The function returns 500, so the
forwarder parks the message in its DLQ and retries it — the same card read
comes back every few minutes until the publish works or the entry ages out.

### `Not implemented: ClientRequest.options.createConnection`

This one in the `functions` log is that last hop failing, and it takes
`send-credit`, `trigger-ota` and `send-device-config` down with the card
flow — everything that publishes MQTT from an edge function.

It came from `npm:mqtt`. The library only uses a native WebSocket when it
detects a *browser* (`window.document`); in Deno it takes its Node path,
which builds the WebSocket upgrade with the `ws` package, and `ws` sets
`options.createConnection` on the request. Older Deno builds — including the
one inside the pinned `supabase/edge-runtime` image — do not implement that
option and throw before a single byte reaches the broker.

`_shared/mqtt-publish.ts` therefore speaks MQTT 3.1.1 over a native
`WebSocket` itself (CONNECT / PUBLISH / PUBACK / DISCONNECT, about a hundred
lines, covered by `mqtt-publish.test.ts`). Nothing in the edge functions
touches `node:http` any more.

### Other things that bite after a deploy

- **The reader is on the Pulse connector.** That connector is an output (see
  Wiring); nothing wired to it can ever reach the SoC. `rx` at 0 in the
  diagnostics while a card is presented is exactly this symptom.
- **The broker never learned about `/card`.** `Docker/mqtt/config/acl` grants
  `vmflow` write on `/+/+/card`, but mosquitto reads that file only at
  startup, so an installation updated in place is still enforcing the ACL it
  booted with: `docker compose kill -s HUP broker` re-reads it without
  dropping a client (a restart works too).

  This failure is **silent on both ends**. The broker ACKs the denied QoS 1
  publish and drops it, so the device logs a successful publish, and at the
  default log level the broker says nothing either — `mosquitto_sub` on the
  topic simply stays empty. To see it, uncomment `log_type all` in
  `Docker/mqtt/config/mosquitto.conf`, reload, and watch for:

  ```
  Denied PUBLISH from <client-id> (d0, q1, r0, m1, '/co/dev/card', ... (13 bytes))
  ```
- **The forwarder never subscribed to `/card`.** The topic list lives in the
  forwarder image; `docker compose up -d --build forwarder` after an update.
- **The migration is not applied.** No `card_accounts` table means the
  webhook 500s on `card_account_resolve`. `Docker/update.sh` applies pending
  migrations.
