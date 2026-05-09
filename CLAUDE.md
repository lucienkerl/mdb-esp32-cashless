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
- Telemetry reader on UART1 (GPIO43 TX, GPIO44 RX) for DEX/DDCMP data

**MDB State machine**: `INACTIVE → DISABLED → ENABLED → IDLE → VEND → IDLE`

**Security**: MQTT and BLE payloads use XOR obfuscation with an 18-byte `passkey` plus a ±8 second timestamp window to prevent replay attacks.

**MQTT topics**: `/{company_id}/{device_id}/{event}` where events are: `sale`, `status`, `paxcounter`, `dex`, `mdb-log`, `credit`, `ota`, `config`

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
- **Factory reset** (boot button held 5 s, `factory_reset_task` in main.c) → `nvs_flash_erase()` wipes the **entire NVS partition** including all keys above. The only way to fully clear cellular config without overwriting it.
- **NVS corruption recovery** (NVS init fails with `NO_FREE_PAGES`/`NEW_VERSION_FOUND`) → also a full `nvs_flash_erase`.
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

**Cellular recovery (P4 + post-milestone hardening)**: Multi-layer escalation. Layer 1 — `network.c::ppp_reconnect_task` retries `modem_disconnect`+`modem_connect` 3 times on `IP_EVENT_PPP_LOST_IP`, ~6 s total. Layer 1.5/1.6/2/3 — `cellular_bring_up_task` recovery ladder triggers on **either** IPCP timeout **or phantom-PPP** (TCP probe to 1.1.1.1:53 fails after PPP_GOT_IP). Steps: `modem_pdp_reset` (CGACT=0/1, ~5s) → `modem_rf_reset` (CFUN=0/1, ~10s) → `modem_soft_restart` (CFUN=1,1, ~12s) → `modem_hard_reset` (PMU DC3 cut + PWRKEY, ~15s, true reset). Each step is followed by `modem_connect` + reachability probe; only if probe succeeds is `UPLINK_UP` fired. Worst-case ~3-4 min ladder traversal before bailing OFFLINE; `offline_retry` timer (30s) re-spawns fresh `cellular_bring_up_task`. Layer 4 — `modem.c::modem_watchdog_task` (30 s tick) calls `modem_hard_reset` after 3 consecutive `AT` failures (bounded to 2 hard-resets before deferring to Layer 5). Layer 5 — `mqtt_watchdog_cb` hard-reboots after 10 min without MQTT. MQTT keepalive bumps to 180 s + network/reconnect timeouts to 30 s/20 s when uplink is cellular at `esp_mqtt_client_init` time. Known limitation: at MQTT-init time `network_init()` has not yet run, so `modem_present` is false and cellular boards still get the WiFi-tuned MQTT values on the first connection. The watchdog task is started exclusively from `cellular_bring_up_task` (after `modem_connect` succeeds), so WiFi-only boards never spawn it.

**Phantom-PPP detection (post-milestone)**: SIM7080G has two parallel network stacks (host PPP + internal AT+CIP*/AT+CNACT*) sharing the same PDP context. Residue in the internal stack splits the PDP binding — IPCP completes and inbound flows (cached air-side state) but outbound silently drops at GTP. Field symptom: TLS cert downloads OK, ClientKeyExchange never reaches server, server FINs at 15s timeout. **Three-layer protection**: (1) `modem_init` proactively clears state via `AT+CIPSHUT` + `AT+CNACT=0,0` (best-effort, ignore errors); (2) `modem_connect` verifies PDP via `AT+CGCONTRDP=1` poll (5×1s) after `+CEREG: 1,5` — confirms data attach actually completed before entering DATA mode; (3) `network.c::probe_internet_tcp("1.1.1.1", 53, 5000ms)` runs after `PPP_GOT_IP_BIT` and BEFORE `UPLINK_UP` — failed probe triggers recovery ladder immediately instead of letting MQTT/claim waste minutes on a dead path. **Important**: never call `AT+CGACT=1,1` manually on LTE — the default bearer auto-activates with registration; manual call introduces the race that creates phantom-PPP in the first place. **Note**: `10.0.0.1` in `PPP GOT_IP` log is the SIMCom IPCP peer placeholder (normal), not a stub from a half-broken state.

**Cellular telemetry surface (P5)**: Status MQTT payload is extended additively when uplink is cellular: `online|v:VER|b:BUILD|uplink:cellular|op:NAME|rssi:DBM|mode:RAT|ip:ADDR`. The `mqtt-webhook` Edge Function parses any `key:value` segments after `parts[2]` and merges them into `embeddeds.mdb_diagnostics.cellular` jsonb (no DB migration). The frontend `CellularHealthBadge.vue` component renders signal bars + operator + mode pill on `/devices` and `/machines/[id]` when `diagnostics.cellular.uplink === 'cellular'`. Old firmware (3-segment status) is unchanged on both sides; the badge renders nothing for non-cellular devices.

**Cellular driver (`modem.c` / `modem.h`)**: SIM7080G driver introduced
in P1. Public API: `modem_probe`, `modem_init`, `modem_connect`,
`modem_disconnect`, `modem_status`, `modem_power_cycle` (single PWRKEY
pulse — cold-boot only), `modem_hard_reset` (true cycle: PMU DC3 cut +
PWRKEY, used by recovery ladder), `modem_pdp_reset` / `modem_rf_reset`
/ `modem_soft_restart` (intermediate recovery layers), plus NVS helpers
`modem_nvs_load`/`modem_nvs_save` (promoted to the public API in P2).
All callers now go through `network.c` — no part of `app_main` touches
`esp_modem_*` directly.

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

`Docker/mqtt/forwarder/main.ts` is a Deno service that subscribes to MQTT topics `/+/+/sale`, `/+/+/status`, `/+/+/paxcounter`, `/+/+/mdb-log` and forwards raw payloads (base64-encoded) to the `mqtt-webhook` Supabase edge function via HTTP POST with webhook secret authentication. The `mqtt-webhook` function decrypts XOR payloads, validates checksum + timestamp (±8s), and writes to Supabase tables. The `mdb-log` topic carries plaintext JSON diagnostics (no XOR encryption).

### Supabase Local Development

```bash
cd Docker/supabase
supabase start    # starts local Supabase on ports 54321 (API), 54322 (DB), 54323 (Studio)
supabase db reset # re-runs all migrations + seed
```

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
- `embeddeds` – registered devices: `subdomain` (bigint, auto-increment), `mac_address`, `passkey`, `status`, `mdb_diagnostics` (jsonb), `vmc_level` (int)
- `sales` – vend events: `embedded_id`, `item_price` (**EUR, not cents**), `item_number`, `channel`, `lat`, `lng`, `machine_id`; has `REPLICA IDENTITY FULL` for realtime delete events
- `paxcounter` – foot traffic: `embedded_id`, `count`
- `device_provisioning` – one-time provisioning codes: `short_code`, `expires_at`, `used_at`, `embedded_id`
- `vendingMachine` – physical machine records linked to embedded devices
- `products`, `product_category` – product catalogue per company; `products.image_path` stores the storage object path; `products.discontinued` (boolean) flag
- `machine_trays` – per-machine tray/slot configuration: `machine_id`, `item_number` (unique per machine), `product_id`, `capacity`, `current_stock`, `fill_when_below` (refill threshold); stock auto-decremented on sales via `stamp_machine_and_decrement_stock` trigger
- `api_keys` – API keys for external integrations: `company_id`, `key_hash`, `key_prefix`, `name`
- `warehouses` – warehouse locations per company
- `product_barcodes` – barcode-to-product mapping for scanning
- `warehouse_stock_batches` – FIFO stock batches with expiry tracking
- `warehouse_transactions` – stock movement log (intake, refill, adjustment, waste)
- `product_min_stock` – per-warehouse minimum stock levels for alerts
- `warehouse_product_positions` – physical layout ordering: `warehouse_id`, `product_id`, `sort_order`, `location_label`
- `low_stock_notifications` – queue table for push alerts when stock drops below minimum; auto-enqueued via trigger
- `stock_decrement_log` – audit log for stock decrements
- `mdb_log` – MDB state-change diagnostics history per device
- `tray_stockout_events` – per-tray stockout history with lost-revenue estimates; trigger-managed (`zzz_tray_stockout_event` on `machine_trays.current_stock`); SELECT-only RLS for authenticated users; uses internal helper `get_product_velocity_one(company_id, product_id, days)` (SECURITY DEFINER, service_role-only, REVOKE PUBLIC)
- `push_subscriptions` – browser push notification registrations (endpoint, keys, user_agent)
- `history` – activity log for audit trail

Key RPC functions:
- `get_machine_insights_kpis(machine_id, company_id, days)` – per-tray KPIs, paxcounter conversion, refill history for AI insights
- `get_product_sales_velocity(company_id, days)` – avg daily units sold per product
- `delete_sale_and_restore_stock(sale_id)` – manual sale deletion with stock restoration
- `insert_manual_sale(machine_id, item_number, price, channel, created_at)` – manual sale insertion
- `deduct_warehouse_stock_fifo(...)` – FIFO warehouse stock deduction for refills
- `analytics_overview(company_id, from, to, compare_from, compare_to, machine_ids[], channels[], category_ids[], vat_rates[])` – KPIs + daily series + top products/machines for /analytics Overview tab
- `analytics_sales_breakdown(..., dimension)` – Sales-tab breakdown by machine/product/category/channel/vat/hour/dow
- `analytics_products(...)` – per-product KPIs + mix-shift series for Products tab
- `analytics_machines(...)` – per-machine KPIs + sales-count heatmaps (dow/hour) for Machines tab
- `analytics_conversion(...)` – Pax × Sales conversion KPIs + heatmaps for Conversion tab
- `analytics_operations(...)` – stockouts + refill tours + stock-cover-days for Operations tab

### Supabase Storage

Buckets defined in `config.toml`:
- `product-images` – public, max 2MiB, PNG/JPEG/WebP; images stored as `{product_id}.{ext}`
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
| `mqtt-webhook` | webhook secret | Receives forwarded MQTT payloads, decrypts + validates + writes to DB |
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
- `mqtt-publish.ts` – reusable MQTT publish helper (connects to broker, publishes, disconnects)
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
- `useMachineTrays()` – CRUD for machine tray/slot configuration; `batchCreateTrays(machineId, startSlot, count, capacity)` bulk-inserts sequential slots; `updateTray()` updates by ID (allows slot number changes); `subscribeToTrayUpdates()` for realtime stock changes; stock auto-decrements on sales via DB trigger
- `useFirmware()` – CRUD for firmware versions in `firmware` storage bucket; `triggerOta(deviceId, firmwareId)` calls `trigger-ota` edge function
- `useImportProducts()` – parses Nayax Excel exports, previews products, bulk imports via `import-products` edge function
- `useNotifications()` – browser push notification registration and management via `register-push` edge function
- `useWarehouse()` – CRUD for warehouses, stock batches (FIFO), transactions, barcode lookups, min-stock alerts; `deductStock()` calls `deduct_warehouse_stock_fifo` DB function for refill operations
- `useMdbLog()` – fetches MDB diagnostics history from `mdb_log` table with realtime subscription
- `useActivityLog()` – activity/audit log composable

**Refill & insights:**
- `useRefillWizard()` – multi-step refill tour state: packing → refill → summary; combined/per-machine picking modes, warehouse stock tracking, persistent state for resume
- `useTourHistory()` – fetches activity log entries grouped by `tour_id` (with 10-min fallback grouping), enriches user display names
- `useStockHistory()` – merges stock events from sales, activity log, and `stock_decrement_log` into unified tray timeline
- `useInsights()` – manages AI-powered machine/company insights, history, loading states via `machine-insights` edge function
- `useProductImageSearch()` – wraps `search-product-images` edge function with debounce and caching

**UI utilities:**
- `useTheme()` – wraps `useDark` from `@vueuse/core`; theme persisted to `localStorage` as `color-scheme`
- `useAppResume()` – app lifecycle/resume event handling
- `useAppUpdate()` – detects new service worker versions, provides `applyUpdate()` to reload
- `useInstallPrompt()` – PWA install prompt handling with iOS detection and dismissal tracking
- `usePullToRefresh()` – registers page-level pull-to-refresh handler via shared `useState`
- `useModalForm()` – generic reusable modal form state (open/close, form data, loading, error, submit)
- `useTableSort()` – generic table sorting with key + direction toggle

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
- `/machines/[id]` – Per-machine detail: 30-day chart + sales history (with product image thumbnails from trays, manual sale add/delete); Trays & Stock tab with tray table, batch add (sequential slots), single add/edit (editable slot numbers), refill, and delete; AI insights tab
- `/products` – Products tab (table with image thumbnails, add/edit modal with image upload zone + image search, category selector, discontinued flag) + Categories tab + Import from Nayax Excel
- `/warehouse` – Warehouse inventory management: stock intake with barcode scanning (`BarcodeScanner` component), FIFO batch tracking, transaction history, min-stock alerts, product position management
- `/refill` – Multi-step guided refill wizard: select warehouse → pack items (combined/per-machine mode) → refill trays → summary with tour stats
- `/tour-history` – Expandable list of completed refill tours with per-machine details, user names, timestamps
- `/history` – Activity/audit log
- `/devices` – Admin device management: registered embedded devices table, register new device with provisioning code + QR, pending tokens, delete device
- `/firmware` – Firmware version management: upload .bin files + import from GitHub releases, deploy OTA to devices, delete versions
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

Edge function tests (Deno): `Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts`
