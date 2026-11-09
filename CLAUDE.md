# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

An open-source MDB (Multi-Drop Bus) cashless payment implementation for vending machines using ESP32-S3. The system has four main parts:

- **mdb-slave-esp32s3** – ESP32-S3 firmware acting as an MDB cashless device (peripheral)
- **mdb-master-esp32s3** – ESP32-S3 firmware simulating a VMC (vending machine controller) for testing
- **Docker** – Self-hosted backend: Supabase (PostgreSQL + auth + edge functions), MQTT broker, Deno MQTT forwarder
- **management-frontend** – Nuxt 4 management dashboard (TypeScript, shadcn-nuxt, TailwindCSS 4, PWA, i18n)

---

## Firmware (ESP-IDF)

Both components use **ESP-IDF v5.x** with CMake and FreeRTOS.

```bash
. $IDF_PATH/export.sh   # activate ESP-IDF environment first

idf.py build
idf.py flash monitor
idf.py menuconfig       # hardware pins, features
```

### mdb-slave-esp32s3 Architecture

Single main file `main/mdb-slave-esp32s3.c` runs these concurrent FreeRTOS tasks:
- `mdb_cashless_loop` – MDB protocol handler on UART2 (GPIO4 RX, GPIO5 TX, 9600 baud, 9-bit mode)
- `bleprph_host_task` – NimBLE BLE peripheral (in `nimble.c`) for legacy device config and vend approvals
- MQTT client over WiFi for credit delivery and sales publishing
- Telemetry reader on UART1 (GPIO9 TX, GPIO8 RX — `PIN_DEX_TX`/`PIN_DEX_RX`, configured unconditionally at boot) for DEX/DDCMP data
- `rfid_reader_task` – serial RFID card reader (F02DC) on UART0, RX = the pulse input (GPIO13), 9600 8N1

**MDB State machine**: `INACTIVE → DISABLED → ENABLED → IDLE → VEND → IDLE`

**Status LED** (`vTaskBitEvent` in `mdb-slave-esp32s3.c`, one WS2812 on `PIN_MDB_LED`):
periodic pattern engine (50ms tick), not just one-shot solid colors. `led_compute_state()`
evaluates a fixed priority ladder each tick — the first matching rule wins. Brightness is one
global knob, `LED_BRIGHTNESS_SCALE` (0-255), applied to every color including the boot
self-test. Every boot starts with a ~750ms red/green/blue self-test flash (pure channels, via
`led_set_scaled_pixel`) so a dead channel is visible immediately, before the states below apply.

| # | State | Color(s) | Pattern |
|---|---|---|---|
| 1 | MDB checksum/bus error (last 3s) | Red | Fast blink |
| 2 | OTA update in progress | Purple | Fast blink |
| 3 | Vend in progress (`machine_state == VEND_STATE`) | White | Pulse |
| 4 | Not installed, claim POST in flight | Yellow | Double-blink |
| 5 | Not installed, last claim attempt failed | Orange | Slow blink |
| 6 | Not installed, WiFi connecting / cellular registering | Yellow | Fast blink |
| 7 | Not installed, `network_init()` not yet resolved (boot) | White | Pulse |
| 8 | Not installed, SoftAP up waiting for input | Yellow | Slow blink |
| 9 | Installed, MQTT up + reader enabled (both axes agree) | Green | Solid |
| 10 | Installed, any other reader/MQTT combination (axes disagree) | Green/Red (MQTT) + Green/Blue (reader) | Alternate |

State 10 is a deliberate two-axis signal, not a single collapsed color — answers "is it
online" before "is MDB talking", the priority the device's user cares about. `led_compute_state`
picks a **connectivity color** (green=MQTT up, red=down) and a **reader color** (green=MDB
reader enabled, blue=idle/not enabled) independently; if they're the same color (state 9) it
shows solid, otherwise it shows both via `LED_PATTERN_ALTERNATE`: connectivity color 250ms,
reader color 500ms, 1000ms pause, repeat (40-tick cycle at the 50ms base). The pause is the
landmark — whichever color follows a gap is always the connectivity one, so you don't need to
catch the start of the cycle or judge relative durations to read it. (Old design showed one
solid/blinking color per combination, e.g. a fully-online device with no VMC attached yet and a
truly offline device both showed solid red — indistinguishable and misleading.)

Inputs: `xLedEventGroup` bits (installed/reader-enabled/MQTT-up) plus plain globals owned by
other subsystems — `machine_state`, `ota_in_progress`, `s_prov_claim_running`/`s_prov_claim_failed`
(provisioning), `network_get_status()` (network.c). The task is spawned right after the LED
strip driver init (before `network_init()`, which blocks for 1-20s on `modem_probe()`) so state
7 above is actually reachable — otherwise the LED stays dark for that whole window. Stack is
4096 (not 2048 — the pattern engine's `network_status_t` local plus the RMT call chain blew a
2048 stack with a raw Guru Meditation crash, not a clean overflow message).

**EXPANSION REQUEST ID** (`0x07`/`0x00`) is answered with the Level 1 30-byte
Peripheral ID, built once at task start by `mdb_build_peripheral_id()`. Some
VMCs reject it however it is formatted and only proceed once the reader goes
quiet; others (SandenVendo SN02-B) stay in DISABLED forever until it is
answered. The firmware answers up to `MDB_ID_MAX_ATTEMPTS` times per reset
cycle and then stays silent, which satisfies both.

**Security**: MQTT and BLE payloads use XOR obfuscation with an 18-byte `passkey` plus a ±8 second timestamp window to prevent replay attacks.

**Money arithmetic (`scale_factor.h`)**: MDB carries prices as integers in
scale-factor units (a cent at the configured scale 1 / 2 decimals). The
conversion goes through `pow(10, -dec)`, which is not exactly representable,
so the round trip lands just *below* the integer it should hit — 8.20 becomes
819.9999999999999 — and assigning that to an integer truncates. `TO_SCALE_FACTOR`
therefore rounds (`llround`); `FROM_SCALE_FACTOR` stays a plain double because
its result is a currency amount that callers print. The backend does the same
on its side (`functions/_shared/scale.ts`). Both truncating forms were live
once and compounded: a card balance of 8.20 reached the machine as 8.18.
Regression tests: `mdb-slave-esp32s3/test/scale/run.sh` and
`functions/_shared/scale.test.ts`.

**MQTT topics**: `/{company_id}/{device_id}/{event}` where events are: `sale`, `status`, `paxcounter`, `dex`, `mdb-log`, `card`, `credit`, `ota`, `config`, `mdb-trace`, `io`

**I/O test (WROOM-1U only)**: the machine's admin "I/O test" tab (`components/machine/IoTestPanel.vue`, helpers in
`app/lib/ioTest.ts`) is shown only when `mdb_diagnostics.board === 'wroom-1u'` — firmware adds `"board"` to every
`/mdb-log` payload. Config cmd `0x36` (raw `itemNumber` = seconds, `0` = stop, capped at 600 s) starts `io_test_task`,
which publishes plaintext JSON `{"active","left","in":[3],"relay":[2],"ntc","ow":[[{id,t}],[...]]}` to `/io` at QoS 0
(on any input/relay change, else every 5 s; 1-Wire rescanned every 15 s) and puts the relays back as it found them when
the test ends. `0x33`/`0x34` switch relay 1/2, `0x37` beeps the buzzer; all go through `send-device-config`
(`io_test`, `relay1`, `relay2`, `buzzer`). The forwarder treats `/io` as live-only (no DLQ); `mqtt-webhook`
(`io-state.ts`) overwrites `embeddeds.io_state`, which the page follows through realtime. 1-Wire scans are serialised
by `s_onewire_mutex` (the 5-min sensor timer and the test task share the buses). Needs `topic write /+/+/io` in the ACL.

**Temperature sensors**: every `/mdb-log` payload carries the latest readings as
`"temps":{"ntc":41.3,"ow":[{"id":"<ROM id>","b":1,"t":21.5}]}` (cache filled at boot, by the 5-min sensor timer and by
I/O test scans; `ow` absent on the original board), merged into `embeddeds.mdb_diagnostics.temps` with no webhook change.
`vendingMachine.temp_sensors` (`[{id:"ntc"|<ROM id>,name,show}]`, display only) holds the operator's names and which
sensors show next to the machine name (machine page header, Machines panel cards) via
`components/machine/MachineTemperatureBadges.vue`; edited in Machine settings (`TemperatureSensorsSettings.vue`),
helpers in `app/lib/temperatureSensors.ts`. The I/O test panel shows the same names.

**Live MDB bus trace (`mdb_trace.h`)**: on-demand raw capture of every 9-bit word on the bus, shown in the
machine's MDB tab (admin). Off by default; started by config cmd `0x35` (duration in seconds in the *raw*
`itemNumber` bytes 6-7 — not the price param, which goes through the scale factor; `0` = stop, capped at 1800 s;
the device also stops by itself). `read_9`/`read_9_timeout`/`write_payload_9` push into a wait-free SPSC ring
(`mdb_trace_push`, 32-bit atomics only — Xtensa 8/16-bit atomics take a spinlock) — no lock, no network and no
logging in the timing-critical path. `mdb_trace_task` drains it every 500 ms into frames and publishes plaintext
JSON `{"drop":N,"f":[[age_ms,"r"|"t","<3-hex-digit words>"],...]}` to `/{company}/{device}/mdb-trace` at QoS 0
(needs `topic write /+/+/mdb-trace` in `Docker/mqtt/config/acl` — reload the broker). The forwarder never puts
trace batches in the DLQ (stale live data is worthless). `mqtt-webhook` stores one `mdb_trace` row per batch
(pruned to 1 h); the frontend (`useMdbTrace`, `MdbTraceConsole.vue`, decoding in `app/lib/mdbTrace.ts`) reads it
through realtime and computes the wall time as row `created_at` − `age_ms`. Host test: `mdb-slave-esp32s3/test/trace/run.sh`.

**RFID card reader (`rfid_reader.c` / `rfid_reader.h`)**: serial reader
(F02DC and compatibles) on the **pulse pin** (GPIO 13) — no added hardware,
the pin is routed through the GPIO matrix to UART0 (free because the console
is on USB-Serial-JTAG; UART1 is DEX, UART2 the modem). The reader goes on
`io13` of the J4 expansion header, **not** on the three-pin Pulse connector:
that connector is an output (GND, `vin`, and the collector of Q7, whose base
GPIO 13 drives through the 4k7 R27), so a reader wired there never reaches
the SoC. R27 also means the reader's output has to be push-pull; any free pin
(`io1`/`io2`/`io6`) avoids both, via `CONFIG_RFID_RX_GPIO`. Frames are
`0x02 | LEN | TYPE | DATA… | XOR | 0x03`, parsed delimiter-driven and
validated by the XOR byte rather than by trusting `LEN` (vendors disagree
about what it counts). Readers repeat the serial while the card sits on the
antenna, so repeats within `CONFIG_RFID_DEDUP_MS` (default 5 s) are dropped
and each repeat slides the window — **one presentation is one backend
request**. A card that could not be reported clears the dedup memory so the
customer can simply present it again. Counters (`ok`/`bad`/`cards`/`dup`/`rx`, the last one raw bytes read)
ride along in the `/mdb-log` diagnostics payload and are shown on the
machine's MDB diagnostics card; a burst that parses into nothing is also
hex-dumped to the console (rate-limited), which is what tells a mute
reader apart from one speaking another dialect. Card presentations are
published to `/{company}/{device}/card` as a variable-length payload
(cmd `0x25`, see `card_payload_encode`) because the 19-byte sale payload has
no room for a UID. Full write-up: `docs/integrations/rfid-card-reader.md`.

**NVS namespace `vmflow`** keys:
- `company_id` – UUID from companies table
- `device_id` – UUID from embeddeds table
- `passkey` – 18-char XOR cipher key
- `prov_code` – one-time provisioning code (erased after successful claim)
- `srv_url` – backend server URL (also used for OTA)
- `mqtt_host` – MQTT broker hostname
- `mqtt_port` – MQTT broker port
- `mqtt_user` – MQTT username
- `mqtt_pass` – MQTT password
- `mdb_addr` – MDB peripheral address selector (1=0x10, 2=0x60), set via config cmd 0x31
- `restart_reason` – set by `tracked_restart()` before reboot, erased on next boot after publish
- `last_uptime` – uptime at the moment of `tracked_restart()`, paired with `restart_reason`
- `apn` – cellular APN (P1+, set via captive portal `/api/v1/cellular/configure`)
- `sim_pin` – optional cellular SIM PIN (P1+; empty for PIN-less SIMs)
- `lte_mode` – cellular LTE mode selector u8 (1=Cat-M, 2=NB-IoT, 3=Both)

**Reset paths and what they erase:**
- **Factory reset** (boot button held 5 s, `factory_reset_task` in main.c, or the captive portal's "Reset this device" → `POST /api/v1/system/reset`) → `cred_backup_erase()` + `nvs_flash_erase()` wipe the **entire NVS partition** including all keys above, and the credentials backup. The only way to fully clear cellular config without overwriting it. The portal reset is refused (403) unless the request came in over the SoftAP itself (the REST server also listens on the STA/LAN side), and on a claimed device whose SoftAP has no password (anyone near the machine can join an open AP).
- **NVS corruption recovery** (NVS init fails with `NO_FREE_PAGES`/`NEW_VERSION_FOUND`) → also a full `nvs_flash_erase`, **followed by a restore from the credentials backup** (below), so the device comes back claimed and on its WiFi instead of factory-new. The boot also restores when NVS is healthy but `company_id` is gone while a backup exists. Either case sets `restart_reason` to `nvs_erased_restored` / `nvs_lost_restored`.

**Credentials backup (`cred_backup.c` / `cred_backup_format.h`)**: second copy of NVS namespace `vmflow` (all keys except `prov_code`, `restart_reason`, `last_uptime`) plus the WiFi STA SSID/password (pseudo keys `#wifi_ssid`/`#wifi_pass`), CRC-protected, in the **`phy_init` partition** — present in both partition tables but unused because `CONFIG_ESP_PHY_INIT_DATA_IN_PARTITION` is off (`cred_backup.c` refuses to build if it is turned on). No partition table change, so OTA-updated boards get it. Refreshed on every `UPLINK_UP` of a claimed device, rewritten only when the content changed. Restore never overwrites a key that exists; WiFi is restored in `network_init()` only when the STA config is empty. Host test: `mdb-slave-esp32s3/test/cred_backup/run.sh`.

**NVS headroom**: the slow-path sale queue (`sale_queue.c`, 3 NVS entries per sale) stops queueing (counts overflow) once fewer than one page + 48 entries of NVS are free, and erases a slot's blob on PUBACK; `sale_queue_init` erases every non-pending slot key once at boot. Before, drained slot blobs stayed forever and the slot key is `tail % 512`, so every slow-path sale over the device's lifetime left a new key behind — on the original board's 16 KB NVS a few dozen in total fill it, no long outage needed.

**Legacy BLE WiFi commands** (`ble_event_handler` 0x06 SSID / 0x07 password) are ignored on a claimed device: the characteristic is writable by anyone in range without pairing.
- **Successful claim** (`provision_claim_task`) → erases only `prov_code`. Cellular config persists across the post-claim reboot, which is the intended behaviour (post-claim devices keep their APN).
- **Soft restarts** (OTA, MQTT watchdog, config cmd 0x30, provision-failure retry loop) → reboot only, no NVS keys touched. Cellular config persists, which is intended (so the device re-attaches to the same APN automatically).
- **`/api/v1/cellular/configure`** rejects empty APN — once set, an APN can only be **overwritten** (with a new value), not gap-deleted via the captive portal. Factory reset is the only way to fully clear it.

**WiFi / provisioning boot flow**:
1. On `WIFI_EVENT_STA_START`, calls `esp_wifi_connect()`. If it returns an error (no saved credentials), immediately starts SoftAP + captive portal DNS + HTTP server.
2. On repeated `WIFI_EVENT_STA_DISCONNECTED` (retry limit hit), also starts SoftAP.
3. Captive portal serves `webui/index.html` (embedded via CMakeLists `EMBED_FILES`). User enters WiFi credentials + provisioning code + server URL.
4. `webui_server.c` saves `prov_code` and `srv_url` to NVS, then calls `esp_wifi_connect()`.
5. On `IP_EVENT_STA_GOT_IP`, if `prov_code` is in NVS, spawns `provision_claim_task` instead of starting MQTT.
6. `provision_claim_task` POSTs `{short_code, mac_address}` to `{srv_url}/functions/v1/claim-device`, saves returned `company_id`, `device_id`, `passkey`, `mqtt_host`, `mqtt_port` to NVS, erases `prov_code`, calls `esp_restart()`.
7. After reboot, device finds `company_id` + `device_id` + `passkey` in NVS and starts MQTT normally.

**CMakeLists.txt**: Uses explicit `REQUIRES` — adding a new header include likely requires adding the owning component to `REQUIRES` in `main/CMakeLists.txt` (e.g. `esp_wifi`, `esp_http_client`, `mqtt`, `driver`, `bt`, etc.).

**Network manager (`network.c` / `network.h`)**: Single orchestrator for
the device's uplink. At boot, `network_init()` calls `modem_probe()` and
branches:
- **Modem detected** → cellular-only boot. WiFi STA is NOT initialised.
  SoftAP comes up immediately. If an APN is in NVS (post-claim or
  pre-configured), `cellular_bring_up_task` runs `modem_init` +
  `modem_connect`. P3 captive portal calls `network_cellular_configure`
  with new credentials.
- **No modem** → WiFi-only boot. Behaviour identical to the pre-P2
  firmware: `esp_wifi_init` + STA/AP netifs + `esp_wifi_start`. SoftAP
  comes up after `WIFI_SOFTAP_AFTER` failed connect attempts.

`mdb-slave-esp32s3.c` registers a single callback via
`network_register_callback` that fires on `NETWORK_EVENT_UPLINK_UP` —
the callback either spawns `provision_claim_task` (first-boot claim
flow) or starts the MQTT client. The pre-P2 inline `wifi_event_handler`
(~165 lines) was extracted into `network.c`.

**Captive portal wizard (P3)**: `webui_server.c` exposes
`GET /api/v1/system/info` (returns `{variant, wizard_state, uplink:{kind,wifi,cellular}, claim:{claimed, prov_code_set}}` from `network_get_status()`),
plus three POST endpoints: `/api/v1/cellular/configure` `{apn, pin, lte_mode}`,
`/api/v1/wifi/configure` `{ssid, password}` (rejected on cellular boards),
and `/api/v1/claim` `{prov_code, srv_url}` (writes NVS + spawns
`provision_claim_task` from `provision.h`).
The captive portal HTML (`webui/index.html`, embedded via `EMBED_FILES`)
is a vanilla-JS SPA: polls `/system/info` every 2 s, renders one of 7
wizard-state views (booting, offline, cellular_config, cellular_registering,
wifi_connecting, ready_to_claim, claimed), shows a status banner with
signal bars + operator + IP, and disables submit buttons during in-flight
or registering states. The old combined `/api/v1/settings/set` endpoint
was removed in P3.

**Uplink switch — WiFi instead of cellular (Option A)**: a modem-equipped board can be switched
to run on WiFi instead of cellular, and back, via the captive portal — never both at once, and
never live: `network_init()` only branches once at boot, so switching always reboots. Three new
NVS keys in `vmflow`: `uplink_pref` (u8, 0=cellular/default, 1=wifi — read at the very top of
`network_init()`, before `modem_probe()`; when set, the probe is skipped entirely and
`s_user_committed_wifi` is set the same way `network_skip_modem_probe()` sets it for a live
in-progress probe) and `has_modem` (u8, sticky — set the first time any boot's `modem_probe()`
returns true, never cleared short of factory reset; needed because `modem_is_present()` reads
false once already running in WiFi mode, so it can't by itself tell "genuinely WiFi-only
hardware" from "a cellular board currently choosing not to use it"). `network.c` exposes
`network_set_uplink_preference(prefer_wifi, ssid, password)` / `network_get_uplink_preference()`
/ `network_has_cellular_hw()`. `webui_server.c`'s `POST /api/v1/uplink/prefer`
`{prefer: "wifi"|"cellular", ssid?, password?}` calls it, saves WiFi credentials in the same
request when switching to WiFi (so the next boot connects immediately, no second SoftAP
round-trip), and reboots via `tracked_restart` (exposed through the new `restart.h`, mirroring
`provision.h`'s pattern for reaching an `mdb-slave-esp32s3.c` function from `webui_server.c`).
`GET /api/v1/system/info` gained `uplink_switch: {available, preference}`; the captive portal's
"claimed" view (`webui/index.html`) renders a switch control keyed off `available`, not
`variant` — same reasoning as `has_modem` above. Wasn't feasible to bolt on top of the existing
either/or boot branch without changes: WiFi driver + both netifs already run in APSTA mode
simultaneously with the modem at boot (this was already true before this feature — SoftAP has
to survive `modem_probe()` glitch-free), so the actual gap was event-handler registration +
auto-connect being withheld on the cellular branch, not missing hardware/driver init.

**Cellular recovery (P4 + post-milestone hardening)**: Multi-layer escalation. Layer 1 — `network.c::ppp_reconnect_task` retries `modem_disconnect`+`modem_connect` 3 times on `IP_EVENT_PPP_LOST_IP`, ~6 s total. The `IP_EVENT_PPP_LOST_IP` handler sets `s_state = NETWORK_STATE_OFFLINE` before spawning the task — do not remove this: the task's own first move under `modem_op_lock` is "if `s_state` is already `CELLULAR_UP`, another recovery path beat us to it, bail out." Without the handler clearing state first, that guard is trivially true on every single LOST_IP (nothing else touches `s_state` in between), so the task always bailed immediately without ever reconnecting — confirmed live 2026-09-15, the only thing that still worked was the 10-minute Layer 5 hard-reboot. Fix is in and matches the field evidence, but the specific repro (PPP LOST_IP while the app keeps running, no reboot in between) has not been re-triggered live yet to directly confirm `ppp_reconnect_task` now actually reconnects — a same-day SIM pull/reinsert test only exercised the normal cold-boot `modem_probe` path (device happened to be power-cycling for an unrelated reason at that moment), which was never broken. Layer 1.5/1.6/2/3 — `cellular_bring_up_task` recovery ladder triggers on **either** IPCP timeout **or phantom-PPP** (TCP probe to 1.1.1.1:53 fails after PPP_GOT_IP). Steps: `modem_pdp_reset` (CGACT=0/1, ~5s) → `modem_rf_reset` (CFUN=0/1, ~10s) → `modem_soft_restart` (CFUN=1,1, ~12s) → `modem_hard_reset` (PWRKEY toggle-pair, ~15s, true reset). Each step is followed by `modem_connect` + reachability probe; only if probe succeeds is `UPLINK_UP` fired. Worst-case ~3-4 min ladder traversal before bailing OFFLINE; `offline_retry` timer (30s) re-spawns fresh `cellular_bring_up_task`. Layer 4 — `modem.c::modem_watchdog_task` (30 s tick) calls `modem_hard_reset` after 3 consecutive `AT` failures (bounded to 2 hard-resets before deferring to Layer 5). Layer 5 — `mqtt_watchdog_cb` hard-reboots after 10 min without MQTT. MQTT keepalive bumps to 180 s + network/reconnect timeouts to 30 s/20 s when uplink is cellular at `esp_mqtt_client_init` time. Known limitation: at MQTT-init time `network_init()` has not yet run, so `modem_present` is false and cellular boards still get the WiFi-tuned MQTT values on the first connection. The watchdog task is started exclusively from `cellular_bring_up_task` (after `modem_connect` succeeds), so WiFi-only boards never spawn it.

**Phantom-PPP detection (post-milestone)**: SIM7080G has two parallel network stacks (host PPP + internal AT+CIP*/AT+CNACT*) sharing the same PDP context. Residue in the internal stack splits the PDP binding — IPCP completes and inbound flows (cached air-side state) but outbound silently drops at GTP. Field symptom: TLS cert downloads OK, ClientKeyExchange never reaches server, server FINs at 15s timeout. **Three-layer protection**: (1) `modem_init` proactively clears state via `AT+CIPSHUT` + `AT+CNACT=0,0` (best-effort, ignore errors); (2) `modem_connect` verifies PDP via `AT+CGCONTRDP=1` poll (5×1s) after `+CEREG: 1,5` — confirms data attach actually completed before entering DATA mode; (3) `network.c::probe_internet_tcp("1.1.1.1", 53, 5000ms)` runs after `PPP_GOT_IP_BIT` and BEFORE `UPLINK_UP` — failed probe triggers recovery ladder immediately instead of letting MQTT/claim waste minutes on a dead path. **Important**: never call `AT+CGACT=1,1` manually on LTE — the default bearer auto-activates with registration; manual call introduces the race that creates phantom-PPP in the first place. **Note**: `10.0.0.1` in `PPP GOT_IP` log is the SIMCom IPCP peer placeholder (normal), not a stub from a half-broken state.

**Uplink telemetry surface (P5 + WiFi)**: the status MQTT payload carries the uplink additively: cellular `online|v:VER|b:BUILD|uplink:cellular|op:NAME|rssi:DBM|mode:RAT|ip:ADDR`, WiFi `online|v:VER|b:BUILD|uplink:wifi|ssid:SSID|rssi:DBM|ip:ADDR` (`|` and control characters in the SSID become `_`). It is sent on MQTT connect only, so on WiFi the 5-minute `mdb-log` heartbeat also carries a live `"rssi"` (`network_get_wifi_rssi`, stack-light for the esp_timer task); cellular does not, because the modem samples CSQ only while registering. `mqtt-webhook/network-status.ts` stores it in `embeddeds.mdb_diagnostics.network` (`uplink`, `ssid`/`op`, `rssi`, `mode`, `ip`, `measured_at`; heartbeat rssi refreshes it, never a top-level `rssi`) and keeps the older `mdb_diagnostics.cellular` block for cellular uplinks only (dropped on WiFi so a stale one never shows). No DB migration. Clients read it through one pure helper, `app/lib/network.ts` `deviceNetwork()` (falls back to `cellular`), ported 1:1 to iOS `Models/DeviceNetwork.swift` (`HostTests/DeviceNetwork`) and Android `data/DeviceNetwork.kt` (`DeviceNetworkTest`): 0–4 signal levels with separate dBm limits (WiFi −55/−67/−75/−85, cellular −65/−80/−95/−105), colour only for weak (1) and none (0). Web: `NetworkBadge.vue` + `SignalIcon.vue` (WiFi fan vs. bars) on `/devices` and `/machines/[id]`, the Network column of `ConnectivityCard.vue`; iOS/Android: the network after "Contact … ago" on machine cards and a Network section in Device Health. Old firmware (3-segment status) leaves diagnostics untouched; WiFi devices on old firmware show "WiFi or unknown".

**Cellular driver (`modem.c` / `modem.h`)**: SIM7080G driver introduced
in P1. Public API: `modem_probe`, `modem_init`, `modem_connect`,
`modem_disconnect`, `modem_status`, `modem_power_cycle` (single PWRKEY
pulse — cold-boot only), `modem_hard_reset` (PWRKEY toggle-pair, used by
recovery ladder — no PMU on the production board to power-gate the
modem), `modem_pdp_reset` / `modem_rf_reset`
/ `modem_soft_restart` (intermediate recovery layers), plus NVS helpers
`modem_nvs_load`/`modem_nvs_save` (promoted to the public API in P2).
All callers now go through `network.c` — no part of `app_main` touches
`esp_modem_*` directly. Pins default to the SIM7080G board (RX 18, TX 17,
PWRKEY 14); `modem_set_pins()` overrides them before `network_init()`.

**LTE add-on on the WROOM-1U (`kicad/lte-addon-sim7080g`)**: the WROOM-1U has
no modem of its own, so `app_main` calls `network_disable_modem_probe()` there
(the default modem pins GPIO17/18 are custom inputs 2/3 on that board) —
unless the plug-in SIM7080G module sits on its J2 socket. The module pulls
GPIO42 up with 10k; `detect_lte_addon()` reads it with the internal pull-down
and, when HIGH, selects RX 39 / TX 40 / PWRKEY 41 (same inverted PWRKEY drive)
and lets the normal cellular boot run. The module's KiCad files are generated
from `scripts/design.py` (KiCad 9, `scripts/build.sh` + `fab.sh`; see its README).

### mdb-master-esp32s3 Architecture

VMC simulator, polls MDB peripherals at addresses 0x08, 0x10, 0x60. Button ISR (`button0_isr_handler`) triggers a vend cycle. LED strip on GPIO48. DEX reader on GPIO17/18.

---

## Docker Backend

All services configured via `Docker/.env` (copy from `.env.example`). Run commands from the `Docker/` directory.

```bash
# Start all services (Supabase + API gateway + MQTT broker + forwarder)
docker compose up

# Tear down everything
docker compose down -v --remove-orphans
```

### Key Services

| Service | Purpose |
|---------|---------|
| `kong` (port 8000) | API gateway |
| `db` | PostgreSQL 15.8 |
| `auth` | Supabase GoTrue |
| `rest` | PostgREST API |
| `realtime` | Supabase Realtime |
| `storage` | Supabase Storage |
| `imgproxy` | Image transformation proxy |
| `meta` | Postgres Meta |
| `functions` | Deno edge runtime |
| `studio` (port 54323) | Supabase Studio dashboard |
| `broker` (port 1883) | Eclipse Mosquitto MQTT |
| `forwarder` | Deno MQTT→Supabase webhook bridge |
| `frontend` (port 3000) | Nuxt 4 management app |

### MQTT Forwarder

`Docker/mqtt/forwarder/main.ts` is a Deno service that subscribes to MQTT topics `/+/+/sale`, `/+/+/status`, `/+/+/paxcounter`, `/+/+/mdb-log`, `/+/+/card` and forwards raw payloads (base64-encoded) to the `mqtt-webhook` Supabase edge function via HTTP POST with webhook secret authentication. The `mqtt-webhook` function decrypts XOR payloads, validates checksum + timestamp (±8s), and writes to Supabase tables. The `mdb-log` topic carries plaintext JSON diagnostics (no XOR encryption).

### Supabase Local Development

```bash
cd Docker/supabase
supabase start    # starts local Supabase on ports 54321 (API), 54322 (DB), 54323 (Studio)
supabase db reset # re-runs all migrations + seed
```

`config.toml` sets a unique `project_id = "mdb-esp32-cashless"` so the CLI's local Docker containers/volumes (`supabase_db_mdb-esp32-cashless`, …) don't collide with other local Supabase projects on the same host. Two projects sharing a `project_id` would share one local database — bleeding each other's migration history and breaking `supabase migration up`. Run the CLI from `Docker/supabase` and start only one stack at a time (ports are shared on the defaults).

### Database Migrations (IMMUTABLE)

**Migrations in `Docker/supabase/migrations/*.sql` are immutable once committed to `main`.** Never edit an existing migration file after it has been pushed — always create a new migration with a later timestamp instead.

**Why this matters**: `Docker/update.sh` tracks applied migrations by filename (in `public._migrations`), not by content hash. Editing an already-applied migration leaves every existing database running the OLD version while git source carries the NEW one — a silent divergence that stays latent until the buggy code path is finally executed. This happened once (2026-04-11) with `20260406000000_tax_infrastructure.sql`: the `stamp_machine_and_decrement_stock` trigger was first committed with `ROUND(NEW.item_price / ...)` where `item_price` is `float8` (producing the runtime error `function round(double precision, integer) does not exist`), and later the same file was edited in commit `69effe6` to add `::numeric` casts. Every DB that had already applied the first version kept the buggy trigger; the bug only surfaced days later when the first sale satisfied the `v_tax_rate IS NOT NULL` guard, killing the MQTT sales pipeline for ~24h.

**How to fix a bug in an existing migration:**

1. Leave the old migration file untouched
2. Create a new migration `YYYYMMDDHHMMSS_fix_<short_description>.sql` with a higher timestamp
3. Use idempotent operations: `CREATE OR REPLACE FUNCTION`, `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, `DROP TRIGGER IF EXISTS` / `CREATE TRIGGER`, etc.
4. The new migration will automatically be applied by `update.sh` on every existing installation and is a no-op on fresh installs that already got the fixed version via ordered apply

**Enforcement:** `.githooks/pre-commit` rejects staged changes to migration files that already exist on `origin/main`. Install once per clone with `scripts/install-git-hooks.sh` (sets `core.hooksPath`). To intentionally bypass — only when you are certain the migration has never been applied anywhere (e.g. you created it in the same uncommitted session) — commit with `--no-verify`.

### Database Schema

Multi-tenancy model: users belong to `companies` via `organization_members`. All RLS policies use the helper functions `my_company_id()` and `i_am_admin()` which read from `organization_members` for the current JWT user.

Tables:
- `companies` – organisations; has `anthropic_api_key` (nullable) for AI insights, `velocity_days` (default 30) for sales velocity calculation
- `organization_members` – `(company_id, user_id, role)` where role ∈ `{admin, viewer}`
- `invitations` – email-scoped invite tokens with expiry
- `embeddeds` – registered devices: `subdomain` (bigint, auto-increment), `mac_address`, `name` (nullable text, admin-assigned label), `passkey`, `status`, `mdb_diagnostics` (jsonb), `vmc_level` (int)
- `sales` – vend events: `embedded_id`, `item_price` (**EUR, not cents**), `item_number`, `channel`, `lat`, `lng`, `machine_id`; has `REPLICA IDENTITY FULL` for realtime delete events
- `paxcounter` – foot traffic: `embedded_id`, `count`
- `device_provisioning` – one-time provisioning codes: `short_code`, `expires_at`, `used_at`, `embedded_id`
- `vendingMachine` – physical machine records linked to embedded devices; `nayax_machine_id` (nullable text, UNIQUE per company) maps to a Nayax serial for `/reports/nayax-reconciliation`; `contact_phone`/`whatsapp_phone`/`support_hours`/`contact_email` are nullable **overrides** of the company imprint used by printed posters (empty = inherit); `linked_selections` (boolean, default false, display only) marks a machine that vends from a sibling slot on its own when one is empty — the clients then hide the "slot empty, product in another slot" hint for it (set in Machine Settings on the web app)
- `products`, `product_category` – product catalogue per company; `products.image_path` stores the storage object path; `products.discontinued` (boolean) flag; `product_category.min_age` (nullable smallint, e.g. 16/18) is the age restriction every product of the category inherits
- `machine_trays` – per-machine tray/slot configuration: `machine_id`, `item_number` (unique per machine), `product_id`, `capacity`, `current_stock`, `fill_when_below` (refill threshold), `product_assigned_at` (timestamp the current product was assigned to the slot, restamped on product change via trigger), `internal_item_number` (optional "internal tray number": the selection number the machine reports for this slot when it differs from the label; unique per machine, NULL = no mapping); stock auto-decremented on sales via `stamp_machine_and_decrement_stock` trigger. `item_number` is always the **labelled** number: `mqtt-webhook` translates the reported number at ingest (sale + DEX) — a tray whose `internal_item_number` matches wins, otherwise `vendingMachine.item_number_offset` is added (`mqtt-webhook/tray-mapping.ts`). No backfill; `internal_item_number_since` is a server-stamped cut-over the Nayax reconciliation and `dex_reconcile_gaps` use to decide per row. **Stock health is judged per product, not per slot**: all slots of a product in one machine form a group whose stock, capacity, `min_stock` and `fill_when_below` are summed (`groupTraysByProduct` in `management-frontend/app/lib/stock-health.ts`, ported 1:1 to iOS `MachineStockHealth.swift` and Android). A slot that is empty while its product is still in another slot is a hint (`emptySlotsWithStock`), never a critical machine; machine cards, dashboard and refill tour count products, and the refill step spreads packed units emptiest-slot-first (`distributeAcrossSlots`). Push follows the same rule (`mqtt-webhook/product-stock.ts`): the sale push shows the product total when the product sits in several slots, and the low-stock push fires once when the product total reaches its summed `min_stock` and once when it is sold out everywhere, instead of on every sale below the line
- `slot_change_requests` / `slot_change_request_items` / `slot_change_applications` – planned slot re-assignments ("Umbelegen"). Saving the planner only creates a request (one open per machine); each item snapshots the slot's from/to product, capacity, price and the products' category `min_age` (`from_min_age`/`to_min_age`, stamped by a BEFORE INSERT trigger). When the age limit or the price changes, the clients require the refiller to tick "age setting changed" (`age_set`) / "price set" before the slot can be marked rebuilt (unticking takes "rebuilt" back); the server only records `age_set`, so older app versions keep working. Every planned slot of an open request is packed on the next tour; a slot that can't be done is marked "not rebuilt" at the machine and stays open. A request withdrawn while the tour runs (status check when the machine opens, or `apply_slot_change` answering "no longer open") rebuilds nothing at that machine: every slot becomes "not rebuilt", its packed units become leftovers, and the refiller is told if slots were already marked done. Nothing changes on the machine until the next refill tour's refiller accepts and quits the slot via `apply_slot_change`; `slot_change_applications` makes a retried quit a replay. The leftovers of the rebuilds (old stock taken out, packed units not used) are booked once at the end of the tour via `return_slot_change_leftovers`; `slot_change_tour_returns` makes that a replay per `(company, tour)`
- `machine_tour_notes` – "note for next tour": free text the refiller writes at a machine during a refill tour (kebab menu next to "confirm refill"; `save_machine_tour_note(machine_id, tour_id, note)`, one open note per machine and tour, empty deletes). Open notes are shown at the top of the packing step of every tour until the refiller ticks them off there (`complete_machine_tour_notes(note_ids, tour_id)`). Web/iOS/Android alike
- `machine_product_offerings` – per-`(machine_id, product_id)` offering history for the Analysis tab: `offered_since` timestamp tracks how long a product has been offered in a machine **independent of which slot(s) it occupies**. Maintained by an AFTER trigger on `machine_trays` (`maintain_machine_product_offerings`): moving a product between slots keeps the offering open; only removing it from every slot closes it (a later re-add starts a fresh trial). Used so the "testing" grace period survives slot moves.
- `machine_product_removals` – one row per time a product left a machine (in no slot any more): `offered_since`, `removed_at`, `estimated` (backfilled from the last sale / slot change for removals before the table existed). Written by the same `maintain_machine_product_offerings` trigger when it closes an offering; a product that comes back in the same transaction (a slot change that only moves it) drops the row again. `companies.product_removal_cooldown_days` (default 30, 0 = off, edited in web Settings) is how long such a product is flagged in the iOS/Android refill review's replacement picker (red "removed on" pill + what it sold back then, sorted last)
- `poster_layouts` – saved poster configuration per motif: which QR source sits in which slot, the operator's own link, overridden headlines/labels, and the content blocks. `machine_id IS NULL` is the company default, a set `machine_id` overrides it for one machine (partial unique indexes enforce one row each). Read by every member, written by admins.
- `api_keys` – API keys for external integrations: `company_id`, `key_hash`, `key_prefix`, `name`
- `card_accounts` – prepaid RFID card balances: `name`, `balance` (**EUR**), `is_active`, `last_seen_at`. Resolved by the card serial being **contained in `name`**, so `04A1B2C3` can be renamed to `Jane Doe (04A1B2C3)` without breaking the card; an unknown card auto-creates an account at 0
- `card_account_transactions` – append-only ledger behind `card_accounts.balance` (`topup` / `vend` / `adjustment` / `refund`); `UNIQUE(sale_id)` makes a webhook replay charge a vend exactly once
- `card_sessions` – which card account currently holds a device's credit (one open per device, 15 min TTL); how an incoming cashless sale is mapped back to an account
- `warehouses` – warehouse locations per company
- `product_barcodes` – barcode-to-product mapping for scanning
- `warehouse_stock_batches` – FIFO stock batches with expiry tracking
- `warehouse_transactions` – stock movement log (intake, refill, adjustment, waste)
- `product_min_stock` – per-warehouse minimum stock levels for alerts
- `warehouse_product_positions` – physical layout ordering: `warehouse_id`, `product_id`, `sort_order`, `location_label`
- `order_list_items` – products someone put on a warehouse's order list by hand (`added_by_name`, `added_via` web/ios/android; one per warehouse and product). The order suggestion itself is computed in the clients (`app/lib/orderSuggestion.ts`, ported 1:1 to iOS `Models/OrderSuggestion.swift` and Android `data/OrderSuggestion.kt`): avg daily sales × (supplier `order_interval_days` + `lead_time_days` + company `order_buffer_days`) minus warehouse, machine (`companies.order_count_machine_stock`) and on-order stock, rounded up to `products.order_unit_size` cartons; the supplier is `products.preferred_supplier_id`, else the supplier of the latest purchase price
- `purchase_orders` / `purchase_order_lines` – orders marked as placed (`status` ordered → received / closed / cancelled); open lines count as "on the way" in the suggestion. `place_purchase_order` (admin, clears the ordered products' manual entries), `receive_purchase_order` (every member; books each delivered line as an `incoming` transaction with the supplier, `reference_id` = order id; a retry books nothing), `close_purchase_order` (every member; marks delivered without booking, for goods booked by hand or with an older app), `cancel_purchase_order` (admin)
- `low_stock_notifications` – queue table for push alerts when stock drops below minimum; auto-enqueued via trigger
- `stock_decrement_log` – audit log for stock decrements
- `mdb_log` – MDB state-change diagnostics history per device
- `mdb_trace` – short-lived raw bus trace batches per device (`frames` jsonb, `dropped`), written by `mqtt-webhook` only while a trace runs, pruned after 1 h, realtime-published
- `push_subscriptions` – browser push notification registrations (endpoint, keys, user_agent)
- `history` – activity log for audit trail

Key RPC functions:
- `get_machine_insights_kpis(machine_id, company_id, days)` – per-tray (slot-based) KPIs, paxcounter conversion, refill history for AI insights
- `get_machine_product_kpis(machine_id, company_id, days)` – **product-centric** per-machine KPIs for the Analysis tab: aggregates sales by `sales.product_id` (snapshotted at sale time) across all of a product's slots, server-side (no PostgREST row-limit truncation), plus `total_capacity`/`total_stock`/`slots`/`offered_since`
- `get_product_sales_velocity(company_id, days)` – avg daily units sold per product, by `sales.product_id` (the slot's current product only for old sales without a snapshot)
- `delete_sale_and_restore_stock(sale_id)` – manual sale deletion with stock restoration
- `get_recent_product_removals(machine_ids)` – per machine, products removed within the company's cool-down that are still not back, with units sold / revenue / days offered during that offering; read by the refill review's replacement picker on iOS and Android
- `save_slot_change_request(machine_id, items, note)` / `withdraw_slot_change_request(request_id)` – admin-only; upsert the machine's one open slot change request (no-op items dropped, an empty plan closes it). Never touches `machine_trays`
- `apply_slot_change(request_id, tour_id, warehouse_id, items, leftovers)` – called by the refill tour when the refiller quits a machine, **before** `refill_machine_trays`; idempotent per `(request_id, tour_id)`. `done` items switch product/capacity/stock, `skip` items stay open (skip_count). The clients pass an empty `leftovers` list (older app versions still book them here)
- `return_slot_change_leftovers(tour_id, warehouse_id, leftovers)` – called from the refill tour's summary, back at the warehouse: the slot change leftovers of the whole tour, per product, counted by the refiller. Van units go back to the tour's own `outgoing_refill` batches, machine units to a new "machine return" batch with the refiller-confirmed best-before, or both are written off (activity log only); idempotent per `(company, tour)`
- `insert_manual_sale(machine_id, item_number, price, channel, created_at)` – manual sale insertion
- `deduct_warehouse_stock_fifo(...)` – FIFO warehouse stock deduction for refills
- `card_account_resolve(company_id, card_uid)` – find (or auto-create) the card account whose name contains the serial; service role only
- `card_session_open(...)` / `card_session_close(embedded_id, reason)` – open/supersede the device's card session; every non-card credit path (`send-credit`, Stripe, the app via `deliverCredit`) closes it so a paid vend is never charged to whoever tapped last
- `card_account_charge_vend(embedded_id, amount, sale_id)` – subtract a completed cashless sale from the open session's account; no-op when the device has no live session
- `card_account_topup(account_id, amount, description)` – operator-facing signed balance change (admins only), always writing a ledger row

### Supabase Storage

Buckets defined in `config.toml`:
- `product-images` – public, max 2MiB, PNG/JPEG/WebP; images stored as `{product_id}.{ext}`
- `company-logos` – public, max 2MiB, PNG/JPEG/WebP (no SVG: XSS vector in a public bucket); logo stored as `{company_id}.{ext}`, path in `companies.logo_path`
- `firmware` – public, max 5MiB, binary files for OTA updates

To apply only pending migrations without resetting data: `supabase migration up`

### Edge Functions (`Docker/supabase/functions/`)

All functions use `verify_jwt = false` in `config.toml` (workaround for ES256 `CryptoKey` bug in local edge runtime). Identity is verified inside each function via `adminClient.auth.getUser(token)` where `token` is extracted from the `Authorization` header.

| Function | Auth required | Purpose |
|----------|--------------|---------|
| `create-organization` | yes | Create company + make caller admin |
| `invite-member` | admin | Upsert invitation token |
| `accept-invitation` | yes | Join org via invite token |
| `get-my-organization` | yes | Returns `{organization, role}` or `{organization: null}` |
| `create-provisioning-token` | admin | Generate 8-char one-time device code (chars: `ABCDEFGHJKMNPQRSTUVWXYZ23456789`) |
| `claim-device` | none | Called by firmware; validates code, creates `embeddeds` row, returns `{company_id, device_id, passkey, mqtt_host, mqtt_port}` |
| `send-credit` | yes | Encrypt + publish credit to device MQTT topic |
| `request-credit` | yes | Related credit request flow |
| `mqtt-webhook` | webhook secret | Receives forwarded MQTT payloads, decrypts + validates + writes to DB; on `card` resolves the card account and delivers its balance as credit, on a cashless `sale` charges it back |
| `trigger-ota` | admin | Publishes OTA firmware URL to device MQTT topic |
| `import-products` | admin | Bulk import products from Nayax Excel export |
| `register-push` | yes | Register browser push notification subscription |
| `test-push` | yes | Send test push notification |
| `send-device-config` | admin | Send device configuration update via MQTT |
| `create-api-key` | admin | Generate API key for external integrations |
| `check-low-stock` | internal | Reads unsent low-stock notifications, groups by company, sends push alerts, marks as sent |
| `import-github-release` | admin | Import firmware binary from GitHub release tag into storage + firmware_versions |
| `machine-insights` | yes | AI-powered analytics (Claude API): per-machine/company KPIs, recommendations, multi-language, 6h cache |
| `search-product-images` | yes | DuckDuckGo image search for product catalog enrichment |

### Extension Points (Provider Pattern)

Some features have a per-company provider registry rather than a single hardcoded backend. v1 covers `deal-source` (the `/deals` page's data sources). Each extension point's contract lives at `Docker/supabase/functions/_shared/providers/<extension-point>.ts` with built-in providers as TypeScript modules under `_shared/providers/<extension-point>/<provider-id>.ts` and per-company activation in the `provider_settings` table. Documentation per extension point lives at `docs/extension-points/<extension-point>.md` — that file is the SDK; read it before adding a new provider.

### Adding New Environment Variables

When adding a new env var that the frontend or edge functions need in production, update **all** of these:

| File | What to add |
|------|-------------|
| `Docker/.env.example` | Default/placeholder value |
| `Docker/setup.sh` | Generation logic + write to `.env` output |
| `Docker/update.sh` | Auto-generation for existing installs (if applicable) |
| `management-frontend/Dockerfile` | `ARG` + `ENV` (if needed at Nuxt build time) |
| `Docker/docker-compose.yml` | `build.args` for frontend (if needed at Nuxt build time) |
| `Docker/supabase/config.toml` | `[edge_runtime.secrets]` (if needed by edge functions) |

**Frontend build-time vars**: Nuxt `runtimeConfig` reads `process.env` at build time. Any var referenced in `nuxt.config.ts` must be available during `npm run build` inside Docker — this means it must be passed as a Docker build arg (`ARG` + `ENV` in Dockerfile, `build.args` in docker-compose.yml).

**Edge function config**: Each edge function needs a `[functions.<name>]` section in `config.toml` with `import_map` pointing to its `deno.json` file. The self-hosted edge runtime reads secrets from `[edge_runtime.secrets]`.

**Shared modules** (`Docker/supabase/functions/_shared/`):
- `mqtt-publish.ts` – reusable MQTT publish helper (connects to broker, publishes, disconnects). Speaks MQTT 3.1.1 over a **native WebSocket** rather than `npm:mqtt`: the library's Node path builds the upgrade with `ws`, which sets `options.createConnection`, and the edge runtime's node compatibility layer does not implement that — every publish died with `Not implemented: ClientRequest.options.createConnection`. Unit + stub-broker tests in `mqtt-publish.test.ts`
- `scale.ts` – EUR ↔ MDB scale-factor units. Use `eurToScaleUnits()` for anything going onto the wire; never `amount / Math.pow(10, -2)`, which lands below the integer and gets truncated (see the money-arithmetic note in the firmware section)
- `web-push.ts` – web push notification sender

---

## management-frontend

Nuxt 4 (`app/` directory convention), TypeScript, `@nuxtjs/supabase`, shadcn-nuxt, TailwindCSS 4, `@vueuse/core`, `@nuxtjs/i18n` (en/de), PWA (custom service worker).

```bash
cd management-frontend
npm install
npm run dev      # dev server on http://localhost:3000
```

**Environment** (`.env` in `management-frontend/`):
```
SUPABASE_URL=http://127.0.0.1:54321   # port 54321 = API, NOT 54323 (Studio)
SUPABASE_KEY=<anon key>
```

### Auth & Organisation Flow

The `app/middleware/auth.ts` middleware runs on every protected route:
1. Checks `useSupabaseUser()` → redirect to `/auth/login` if unauthenticated
2. **Skips org fetch on SSR** (`import.meta.server`) — the `plugins/supabase-url.client.ts` plugin rewrites the Supabase URL to the browser hostname on the client only; SSR calls would use the raw `127.0.0.1` URL and fail auth
3. On client: calls `fetchOrganization()` from `useOrganization()` composable (cached in `useState('organization')` + `useState('org-role')`)
4. If no organisation → redirect to `/onboarding/create-organization`

Public routes (no auth check): `/auth/login`, `/auth/register`, `/onboarding/*`

### Key Composables

**Core data:**
- `useOrganization()` – wraps `get-my-organization`, exposes `organization`, `role`, `fetchOrganization()`
- `useMachines()` – fetches `vendingMachine` joined with `embeddeds`, batch-fetches per-machine stats (today/yesterday revenue, sales count, paxcounter, last sale) via `Promise.all`; `subscribeToStatusUpdates()` opens Supabase realtime channels on `embeddeds`, `vendingMachine`, and `sales` tables (live-updates today's stats on new sales)
- `useProducts()` – CRUD for products + categories; `uploadProductImage(productId, file)` uploads to `product-images/{id}.{ext}` with upsert; `deleteProductImage()` removes from storage + nulls `image_path`; `deleteProduct()` cleans up storage; `getProductImageUrl(path)` builds public URL; `createProduct()` returns the new product ID
- `usePosterFreshness()` – per machine: does the sign hanging on it still show the current contact data? Recomputes the contact fingerprint from today's data using the blocks the `poster_printed` entry recorded, and compares it with the fingerprint stored at print time — so a motif change or a reprint in another language is not a change, but a new support number is. Drives the "sign out of date" badge on `/machines` and the banner on `/machines/[id]`
- `useMachinePrint()` – data, QR rendering and layout persistence for the printable machine posters (`/machines/[id]/print`): resolves `machine.x ?? company.x` contact data, resolves each motif **slot** to a QR target (machine page / `tel:` / WhatsApp / fault form / the operator's own link / empty), renders them as **SVG** (not data URLs — visibly sharper at 5 cm on paper), loads and saves `poster_layouts`, and writes the `poster_printed` activity entry. The pure logic lives in `app/lib/printSheet.ts` and is unit-tested; motifs declare their slots, editable headlines and blocks in `app/lib/printMotifs.ts`
- `useMachineTrays()` – CRUD for machine tray/slot configuration; `batchCreateTrays(machineId, startSlot, count, capacity)` bulk-inserts sequential slots; `updateTray()` updates by ID (allows slot number changes and the per-tray `internal_item_number`, validated by `app/lib/trayInternalNumber.ts`); `subscribeToTrayUpdates()` for realtime stock changes; stock auto-decrements on sales via DB trigger
- `useMachineAnalysis()` – powers the Analysis tab on `/machines/[id]`. **Product-centric** performance analysis: combines `get_machine_product_kpis` (sales aggregated per product across all its slots), `get_product_sales_velocity` (fleet-wide velocity), the product catalogue, and `machine_product_offerings` tenure. Exposes pure, unit-tested helpers — `slotRowCol`/`computeSlotWidths`/`buildGridSlots` (replicate the iOS layout: 10 columns, `row=max(0,⌊item/10⌋-1)`, `col=item%10`, width=gap to next slot), `scoreProduct` (tier: dead/weak/ok/strong, plus a "testing" grace period for products offered < ~14 days so freshly-placed or brand-new test products aren't condemned), and `buildSuggestionPool` (replacement candidates = proven fleet bestsellers + never-sold "newcomer" test products). `applySwap(trayId, productId)` reassigns a slot's product (resets stock to 0, logs `product_swapped` to `activity_log`)
- `useFirmware()` – CRUD for firmware versions in `firmware` storage bucket; `triggerOta(deviceId, firmwareId)` calls `trigger-ota` edge function
- `useImportProducts()` – parses Nayax Excel exports, previews products, bulk imports via `import-products` edge function
- `useNotifications()` – browser push notification registration and management via `register-push` edge function
- `useWarehouse()` – CRUD for warehouses, stock batches (FIFO), transactions, barcode lookups, min-stock alerts; `deductStock()` calls `deduct_warehouse_stock_fifo` DB function for refill operations
- `useMdbLog()` – fetches MDB diagnostics history from `mdb_log` table with realtime subscription
- `useCardAccounts()` – CRUD for prepaid RFID card accounts plus `adjustBalance()` (via the `card_account_topup` RPC, so the ledger always matches) and the per-account transaction history. Exports the unit-tested `extractCardSerials`/`keepsCardSerials` helpers the rename warning uses — dropping the serial from a name orphans the physical card
- `useActivityLog()` – activity/audit log composable

**Refill & insights:**
- `useRefillWizard()` – multi-step refill tour state: packing → refill → summary; combined/per-machine picking modes, warehouse stock tracking, persistent state for resume. **Packing is one line per machine and product** (`PackLine`: `refill` + `rebuild` units, `slots`, `ticked`, `shortfall`, `max_quantity`; iOS `PackLine`, Android `ui/refill/PackLines.kt`): one tick ("in the box") and one stepper cover the machine's refill of the product and the units for its slot rebuilds (`rebuildPackNeeds` — stock that moves within the machine needs no warehouse stock). `toggleLine` ticks both parts, `setLineQuantity` fills the rebuild first, so packing less takes from the refill first. Ticked lines claim warehouse stock in the order they were ticked (`lineTickSeq`, ties by machine order; Android `SlotChange.commitRebuildInTickOrder`), so a later tick never takes units away from a line already in the box; only ticked units are booked out. Each line reads "needs 9 / 12" (what the product's slots lack / their summed capacity, `refillCapacity`; one "slot 12: 4/4" entry per slot under it when the product sits in several, `refillSlots`) so the refiller can weigh whether a nearly full spiral is worth the trip — the packed amount is the stepper. Product cards in warehouse order (`combinedPackCards`), a box counter (`packBox`) and machines ready, and a confirmation listing the lines not in the box (`openPackLines`; only of machines with at least one ticked line, since an unticked machine was left out on purpose — every machine when nothing is ticked) before the tour starts. A machine's change note (`RefillChangeNote.vue`) is an info-only collapsible banner ("Rebuild 3 slots · 12, 14, 23") plus the spirals to take along. At the machine `RefillRebuildSection.vue` is a tick list (one row per slot: new product, spiral/price/age tags, units going in; iOS `RefillRebuildSection.swift`, Android `RebuildSection`): one tap on the circle marks a slot done, a new price or age limit is confirmed on that tap, and the row opens the removed/filled amounts and "Not possible today", all recorded before `apply_slot_change`; the filled amount is capped by `maxRebuildFilled` (units taken out of the machine's other changed slots + packed − other slots of the product), a skipped source slot is explained (`skippedSourceSlots`), and "rebuilt" needs the price/age confirmation (`needsConfirmation`). Each machine's leftovers are kept in the tour state and booked in one go on the summary step (`RefillTourLeftovers.vue`, `return_slot_change_leftovers`). The `stock_refill_tour` history entry lists the rebuilt slots next to the refilled ones (`rebuild: true`)
- `useSlotChangeRequests()` – load/save/withdraw/apply slot change requests; the pure planning and bookkeeping maths (reach, spirals needed, removal candidates, price changes, fill plan, leftovers) lives in `app/lib/slotChange.ts`
- `useTourHistory()` – fetches activity log entries grouped by `tour_id` (with 10-min fallback grouping), enriches user display names
- `useStockHistory()` – merges stock events from sales, activity log, and `stock_decrement_log` into unified tray timeline
- `useInsights()` – manages AI-powered machine/company insights, history, loading states via `machine-insights` edge function
- `useProductImageSearch()` – wraps `search-product-images` edge function with debounce and caching
- `useNayaxReconciliation()` – Nayax sales export reconciliation: xlsx parsing, timezone helpers (`localDtToUtc`, `parseSelectionInfo`, `parseTitleDateRange`, `derivedChannelFromPaymentSource`), `useState`-shared workflow state, paginated `loadDbSales` (1000-row chunks to defeat PostgREST `max_rows`), greedy one-to-one matcher with ±tolerance, bulk-import via `insert_manual_sale` + per-row ghost delete via `delete_sale_and_restore_stock` (both with `activity_log` entries tagged `source: nayax_reconciliation`), `exportDiffCsv`. Used by `/reports/nayax-reconciliation` page and the `app/components/nayax/*` step components.

**UI utilities:**
- `useTheme()` – wraps `useDark` from `@vueuse/core`; theme persisted to `localStorage` as `color-scheme`
- `useAppResume()` – app lifecycle/resume event handling
- `useAppUpdate()` – detects new service worker versions, provides `applyUpdate()` to reload
- `useInstallPrompt()` – PWA install prompt handling with iOS detection and dismissal tracking
- `usePullToRefresh()` – registers page-level pull-to-refresh handler via shared `useState`
- `useModalForm()` – generic reusable modal form state (open/close, form data, loading, error, submit)
- `useTableSort()` – generic table sorting with key + direction toggle

### Charts

Bar charts (dashboard, machine sales tab, product detail, analytics trend) use `components/charts/BarChart.vue`, a plain-SVG port of the iOS app's Swift Charts style: gradient bars (`--chart-blue` / `--chart-purple`, iOS system colours in `tailwind.css`), weekend bars at 45 % opacity, a dashed orange `Ø` average line, a leading y axis with grid lines, and hover/tap selection with a tooltip card. `ChartAreaInteractive.vue` wraps it in a card with the period total in the header. Pure helpers (local-day bucketing via `dailySeries`, nice ticks, label stride) live in `app/lib/barChart.ts` and are unit-tested. Bucket days by the **local** calendar day (`localDayKey`), never `toISOString().slice(0, 10)` — that is the UTC day and moves early-morning sales onto the previous bar.

### Plugins

- `supabase-url.client.ts` – rewrites Supabase URL to browser hostname (client-only, required for LAN access)
- `register-sw.client.ts` – custom service worker registration (PWA uses custom SW in `public/sw.js`, not Workbox)

### Shared Utilities (`app/lib/utils.ts`)

- `cn()` – Tailwind class merging via clsx + tailwind-merge
- `timeAgo(dt)` – i18n-aware relative time formatting (e.g. "5m ago", "2d ago")
- `formatCurrency(amount)` – formats a number as EUR currency
- `formatDate(dt)` – date formatting
- `formatTime(dt)` – time formatting
- `formatDateTime(dt)` – combined date+time formatting

### Pages

- `/` – Dashboard: KPI cards (today/week sales, machine counts) + 30-day sales chart + activity feed + machine list + recent sales
- `/machines` – Responsive card grid (1/2/3 cols) of vending machines showing status badge, today/yesterday revenue, sales count, last sale time-ago, and paxcounter traffic; cards link to `/machines/[id]`
- `/machines/[id]` – Per-machine detail with tabs: **Sales** (30-day chart + sales history with product image thumbnails from trays, manual sale add/delete); **Trays & Stock** (a stock map of the machine (`components/machine/TrayStockGrid.vue`, colour = the product's status, tap highlights all slots of a product); tray list "By product" (default: a product's slots together under a summary header, `ProductGroupHeader.vue`, ordering/flags in `app/lib/trayGroups.ts`) or "By slot"; batch add (sequential slots), single add/edit (editable slot numbers), refill, delete); **Analysis** (product-centric performance — an iOS-springboard-style layout grid where each slot is colour-coded by its product's tier (dead/weak/testing/ok/strong); a "products to review" list with combined per-product KPIs + machine tenure; one-click replacement with fleet bestsellers or never-sold test products; on-demand AI `product_swap` recommendations); **Umbelegen** (admin, `?tab=slots`, `components/slotplan/SlotPlanPanel.vue`: hints only — products needing more spirals, slow sellers that can go — then drag & drop on the slot grid and a summary of swaps and price changes; saves a slot change request, applied on the next refill tour; the Analysis tab's replace button also queues into that request); plus MDB diagnostics (admin) and Device Health tabs
- `/machines/[id]/print` – Printable contact signage for a machine: seven A4/A5/A6 poster motifs — also offered as three n-up sheets that tile 2 × A5, 4 × A6 or 8 × A7 onto one A4 page, tiles rotated where the arithmetic requires it and separated by dashed cut lines through the gutters — plus eight sticker motifs in three sizes (90×50 mm 8-up, 50×30 mm 24-up, 148×40 mm landscape strip 6-up, all with cut marks), picked from a gallery of live thumbnails rendered from the machine's own data. Every QR slot's source is operator-chosen (machine page / `tel:` / WhatsApp / fault form / own link / empty), headlines and per-slot labels are overridable with a reset-to-default, and the whole configuration saves to `poster_layouts` per company or per machine. Plus per-sheet language, one-off free text, and batch selection across machines. Prints via `window.print()` with `@page` + `print-color-adjust: exact`. Its own route rather than a modal so the app chrome never has to be hidden. The QR origin comes from `SITE_URL` (`runtimeConfig.public.siteUrl`); a LAN or localhost origin raises a blocking-looking warning, because a wrong QR on paper is permanent
- `/products` – Products tab (table with image thumbnails, add/edit modal with image upload zone + image search, category selector, discontinued flag) + Categories tab + Import from Nayax Excel
- `/warehouse` – Warehouse inventory: tabs **Stock** (chips + table, row opens `WarehouseProductSheet.vue` with batches, corrections, min stock, discontinued, order list, main supplier, carton size), **Order** (`WarehouseOrderTab.vue`: suggestion per supplier, manual entries, copy list, mark as ordered, orders on the way), **Incoming** (`WarehouseExpectedDeliveries.vue` for open orders + single intake with barcode scanning) and **History**; admin **Setup** view (warehouses, packing order, suppliers, barcodes, calculation). View/chip logic in `app/lib/warehouseView.ts`, old `?tab=` links are mapped
- `/refill` – Multi-step guided refill wizard: select warehouse → pack items (combined/per-machine mode) → refill trays → summary with tour stats
- `/tour-history` – Expandable list of completed refill tours with per-machine details, user names, timestamps
- `/reports/nayax-reconciliation` – Upload Nayax sales export (.xlsx), wizard with persistent Nayax↔VM mapping (in `vendingMachine.nayax_machine_id`), greedy time-tolerant matcher, three result buckets (matched / missing-in-DB / ghost-in-DB), bulk import of missing as manual sales via `insert_manual_sale`, per-row ghost delete via `delete_sale_and_restore_stock`, CSV diff export. Auditing tagged with `source: nayax_reconciliation` in `activity_log`.
- `/history` – Activity/audit log
- `/devices` – Admin device management: registered embedded devices table, register new device with provisioning code + QR, pending tokens, delete device
- `/firmware` – Firmware version management: upload .bin files + import from GitHub releases, deploy OTA to devices, delete versions
- `/card-accounts` – prepaid RFID card accounts: balances, last use, block/unblock, top-up and correction (both ledgered), per-account history. Admin-only for writes; every member can read
- `/api-keys` – API key management: create/revoke keys for external integrations
- `/members` – Active members table + pending invitations (admin only); invite modal calls `invite-member`
- `/settings` – Application settings (incl. Anthropic API key for AI insights, velocity days config)
- `/server-loading` – Full-screen loading page with auto-retry for server availability
- `/onboarding/create-organization` – Calls `create-organization` edge function
- `/onboarding/accept-invitation` – Reads `?token=` from URL, calls `accept-invitation`

---

## Key Configuration Variables (`Docker/.env`)

- `SUPABASE_PUBLIC_URL` / `API_EXTERNAL_URL` – Public Supabase URL (use LAN IP for dev, e.g. `http://10.0.1.181:8000`)
- `MQTT_HOST` – MQTT broker hostname (LAN IP without port)
- `POSTGRES_PASSWORD`, `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY` – Generated secrets
- `KONG_HTTP_PORT` – API gateway port (default 8000)
- `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` – Web Push notification keys
- `MQTT_WEBHOOK_SECRET` – shared secret between MQTT forwarder and `mqtt-webhook` edge function
- `GITHUB_TOKEN` – GitHub personal access token for firmware import from private repos

---

## Testing

Frontend tests use Vitest (`management-frontend/vitest.config.ts`). Test helpers in `app/test-helpers/nuxt-stubs.ts` provide mock implementations for Nuxt composables.

```bash
cd management-frontend
npx vitest run          # run all tests
npx vitest run --watch  # watch mode
```

Slot re-assignment: `app/lib/__tests__/slotChange.test.ts`, `app/components/__tests__/SlotPlanPanel.test.ts`, `app/composables/__tests__/useRefillWizard.rebuild.test.ts`; DB side `Docker/supabase/tests/slot_change_requests.test.sql` and `category_min_age.test.sql`, `slot_change_tour_returns.test.sql`, `slot_change_offerings.test.sql` (a product that only moves keeps its `machine_product_offerings` row, so it does not drop back into "testing"), `recent_product_removals.test.sql`.

Warehouse ordering: `app/lib/__tests__/orderSuggestion.test.ts`, `app/components/__tests__/WarehouseOrderTab.test.ts`; DB side `Docker/supabase/tests/purchase_ordering.test.sql`; iOS port `ios/HostTests/OrderSuggestion/run.sh` and Android `OrderSuggestionTest.kt` (same cases as the web test). The `Android Check` workflow builds the app and runs its unit tests on every PR touching `android/`.

Firmware host-side tests need no board and compile the real sources:
- `mdb-slave-esp32s3/test/rfid/run.sh` — the F02DC frame parser
  (`main/rfid_reader.c` against a few ESP-IDF stubs): framing, XOR validation,
  duplicate suppression, resync.
- `mdb-slave-esp32s3/test/trace/run.sh` — `main/mdb_trace.h`: frame grouping, gap splitting, ring overflow accounting, batching without torn frames.
- `mdb-slave-esp32s3/test/scale/run.sh` — `main/scale_factor.h`: every credit
  and price value over the whole uint16 MDB range converts exactly.
- `mdb-slave-esp32s3/test/cred_backup/run.sh` — `main/cred_backup_format.h`:
  round trip, erased/torn/bit-flipped images are rejected, identical content
  gives identical bytes (no needless flash rewrite).

Edge function tests (Deno): `Docker/supabase/functions/mqtt-webhook/*.test.ts` (`mdb-log`, `suppress`, `slot-offset`, `tray-mapping`, `stock-urgency`, `product-stock`, `card-payload`) and `Docker/supabase/functions/_shared/*.test.ts` (`notification-i18n`, `scale`, `mqtt-publish` — the last drives the publisher against an in-process stub broker), run with `deno test -A` from the respective directory
