# Per-Device SoftAP Credentials — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every claimed device's SoftAP password unique, generated server-side at claim time and pushed back to the device in the existing claim response. Unclaimed devices expose an **open** SoftAP (no password). SSID becomes per-device via the last 3 bytes of the MAC. Already-claimed devices auto-migrate to the new model on first boot after OTA via a one-shot HTTPS sync call — no factory-reset needed.

**Architecture:** The `claim-device` Edge Function generates a 12-char random password using Web Crypto, persists it in a new `embeddeds.softap_password` column, and returns it in the JSON response. A second Edge Function `sync-softap-password` lets already-claimed devices fetch their backend-assigned password by HMAC-authenticating with their existing `passkey`. Firmware on receipt writes it into NVS `softap_pwd`. `start_softap()` reads NVS — if `softap_pwd` is present and ≥8 chars it brings up the AP as WPA2 with that password, otherwise it brings up an **open** AP (no password). On every boot, if the device is claimed but `softap_pwd` is missing, a sync task spawns on `UPLINK_UP` and fetches the password. The SSID is computed at every boot from the MAC, no NVS dependency. A new `SoftApCredentialsModal.vue` shows credentials + WiFi-QR to admins from `/devices` and `/machines/[id]`.

**Tech Stack:** ESP-IDF v5 (NVS, esp_wifi, cJSON), Supabase Postgres migration, Deno edge function (`crypto.getRandomValues`), Nuxt 4 + Vue 3 + TypeScript, `qrcode` npm package (already installed).

**Spec:** [`docs/superpowers/specs/2026-04-30-softap-per-device-credentials-design.md`](../specs/2026-04-30-softap-per-device-credentials-design.md)

---

## File Inventory

| File | Action | Responsibility |
|------|--------|----------------|
| `Docker/supabase/migrations/20260430120000_softap_credentials.sql` | Create | Add nullable `softap_password text` column to `embeddeds`. |
| `Docker/supabase/functions/claim-device/index.ts` | Modify | Generate `softap_password` on insert, return in response, return existing value on idempotent retry. |
| `Docker/supabase/functions/claim-device/claim-device.test.ts` | Create | Deno test covering generator output (length, alphabet) and the rule that the generator is invoked exactly once per claim. |
| `Docker/supabase/functions/sync-softap-password/index.ts` | Create | New Edge Function: HMAC-authenticated re-sync endpoint for already-claimed devices. Idempotent (NULL → generate; non-NULL → return as-is). |
| `Docker/supabase/functions/sync-softap-password/deno.json` | Create | Standard import-map config matching the other functions. |
| `Docker/supabase/functions/sync-softap-password/sync-softap-password.test.ts` | Create | Deno tests for HMAC verify, timestamp window, mac mismatch, missing device. |
| `Docker/supabase/config.toml` | Modify | Register the new function in `[functions.sync-softap-password]` (dev) — Docker prod picks it up automatically via folder discovery. |
| `mdb-slave-esp32s3/main/webui_server.h` | Modify | Drop `AP_SSID`/`AP_PASS` macros; declare `softap_get_ssid()` / `softap_get_password()` helpers. |
| `mdb-slave-esp32s3/main/webui_server.c` | Modify | Implement helpers; `start_softap()` uses dynamic values; `wifi_scan_get_handler` filter uses dynamic SSID. |
| `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` | Modify | After parsing the claim response, persist `softap_password` to NVS (two response-handling blocks). Add `softap_sync_task` spawned on `UPLINK_UP` for already-claimed devices missing `softap_pwd`. |
| `management-frontend/app/components/SoftApCredentialsModal.vue` | Create | Modal showing SSID + password + WiFi-QR + reveal/copy controls. |
| `management-frontend/app/lib/softap.ts` | Create | `computeSoftApSsid(mac)` + `formatWifiQrPayload(ssid, pwd)` helpers. |
| `management-frontend/app/lib/__tests__/softap.test.ts` | Create | Vitest unit tests for both helpers. |
| `management-frontend/app/pages/devices/index.vue` | Modify | Add `softap_password` to query, add "WiFi" button per row, mount modal, replace legacy provisioning instructions. |
| `management-frontend/app/pages/machines/[id].vue` | Modify | Add modal access from device-info card; add `softap_password` to query. |
| `management-frontend/i18n/locales/en.json` | Modify | Add `softap.*` keys; update `devices.step1`; drop `devices.wifiNetwork` / `devices.wifiPassword`. |
| `management-frontend/i18n/locales/de.json` | Modify | Same as en.json. |

No new edge functions. No new MQTT topics. No new firmware files outside the three modified ones.

## Test Strategy

- **Backend:** new Deno test file for `claim-device` (matches `Docker/supabase/functions/mqtt-webhook/mdb-log.test.ts`). Migration is verified via `supabase migration up` + a manual `\d embeddeds`.
- **Firmware:** SSID + NVS-or-open has no host-test harness in this repo, so verification is **build + on-device**. Build catches missing-include / undefined-macro errors; on-device QA confirms SSID matches MAC, fresh device's AP is open (no password prompt), post-claim device's AP is WPA2 with the backend-assigned password.
- **Frontend:** Vitest unit test for the helpers. Manual UI walkthrough on `npm run dev`.
- **End-to-end manual QA checklist** (Task 13/14) walks the full flow: factory reset → SSID = `VMflow-XXXXXX`, AP open → claim → reboot → SSID same, AP now WPA2 with the backend-generated password → modal in management UI shows the same value. Task 13 also covers the auto-migration scenario: simulate a legacy claimed device, observe the sync task fire, AP transitions from open to WPA2 in place.

## Branch / Worktree

Work on a new branch `claude/softap-per-device-credentials` cut from `main`. The change touches firmware + backend + frontend; isolating in a fresh worktree keeps the in-progress cellular work on `claude/firmware-cellular-milestone` undisturbed.

```bash
git fetch origin
git worktree add -b claude/softap-per-device-credentials ../mdb-esp32-cashless-softap origin/main
cd ../mdb-esp32-cashless-softap
```

Use the `superpowers:using-git-worktrees` skill if needed.

---

## Chunk 1: Backend — Migration + claim-device generator + tests

### Task 1: Add `softap_password` column to `embeddeds`

**Files:**
- Create: `Docker/supabase/migrations/20260430120000_softap_credentials.sql`

- [ ] **Step 1.1: Create the migration file**

```sql
-- Per-device SoftAP credentials.
-- Generated server-side by claim-device starting with build 2026-05-01+.
-- NULL means the device was claimed before this change shipped — after the
-- firmware OTA its SoftAP becomes open (no password) until the device is
-- factory-reset and re-claimed, at which point a backend-generated password
-- is assigned.

ALTER TABLE embeddeds
  ADD COLUMN IF NOT EXISTS softap_password text;

COMMENT ON COLUMN embeddeds.softap_password IS
  'Per-device SoftAP password generated by claim-device at claim time. NULL for rows created by the pre-2026-05-01 backend; such devices fall back to an open AP.';
```

- [ ] **Step 1.2: Apply the migration locally**

Run from the project root (NOT `supabase db reset` — the dev DB has live data):

```bash
cd Docker/supabase
supabase migration up
```

Expected: `Applied migration 20260430120000_softap_credentials.sql`. Anything else, stop and investigate.

- [ ] **Step 1.3: Verify the column exists**

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -c "\d embeddeds" | grep softap_password
```

Expected: a line like `softap_password | text | | |`.

- [ ] **Step 1.4: Commit**

```bash
git add Docker/supabase/migrations/20260430120000_softap_credentials.sql
git commit -m "feat(db): add embeddeds.softap_password column for per-device SoftAP creds"
```

### Task 2: Add password generator + persist + return in `claim-device`

**Files:**
- Modify: `Docker/supabase/functions/claim-device/index.ts:1-9` (helpers)
- Modify: `Docker/supabase/functions/claim-device/index.ts:50-71` (idempotent retry path)
- Modify: `Docker/supabase/functions/claim-device/index.ts:84-133` (insert + response)

- [ ] **Step 2.1: Add `generateSoftApPassword` next to `generatePasskey`**

Insert immediately after the existing `generatePasskey` function (after line 9):

```typescript
// Generates a random 12-character SoftAP password. Alphabet excludes the
// confusable characters 0/O/1/l/I so a technician can read it off the
// management UI and type it without ambiguity.
function generateSoftApPassword(): string {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
  const bytes = new Uint8Array(12)
  crypto.getRandomValues(bytes)
  return Array.from(bytes).map(b => chars[b % chars.length]).join('')
}

export { generateSoftApPassword }
```

(The `export` is for the test file to import.)

- [ ] **Step 2.2: Generate + persist + return on the insert path**

Locate the insert block (currently lines 84-99 — `const passkey = generatePasskey()` followed by `.from('embeddeds').insert(...)`). Replace with:

```typescript
    const passkey = generatePasskey()
    const softapPassword = generateSoftApPassword()

    // Create embeddeds row — subdomain auto-increments
    const { data: embedded, error: embeddedError } = await adminClient
      .from('embeddeds')
      .insert({
        company: token.company_id,
        owner_id: token.created_by,
        mac_address: mac_address ?? null,
        passkey,
        softap_password: softapPassword,
        status: 'offline',
      })
      .select('id, subdomain')
      .single()

    if (embeddedError) throw embeddedError
```

Then in the final return statement (currently lines 122-133), add `softap_password: softapPassword` to the JSON body:

```typescript
    return new Response(
      JSON.stringify({
        company_id: token.company_id,
        device_id: embedded.id,
        passkey,
        softap_password: softapPassword,
        mqtt_host: Deno.env.get('MQTT_PUBLIC_HOST') ?? 'mqtt.vmflow.xyz',
        mqtt_port: Deno.env.get('MQTT_PUBLIC_PORT') ?? '1883',
        mqtt_user: 'vmflow',
        mqtt_pass: 'vmflow',
      }),
      { status: 200, headers: { 'Content-Type': 'application/json' } }
    )
```

- [ ] **Step 2.3: Return the existing value on the idempotent retry path**

Locate the idempotent-retry block (currently lines 50-71 — `if (token.used_at && token.embedded_id)`). The select currently fetches `id, passkey`; extend to also fetch `softap_password`. Then handle the legacy-NULL case (rows created before this change shipped) by generating-and-storing on first retry.

Replace the block with:

```typescript
    if (token.used_at && token.embedded_id) {
      const { data: existing, error: existingError } = await adminClient
        .from('embeddeds')
        .select('id, passkey, softap_password')
        .eq('id', token.embedded_id)
        .single()

      if (existingError) throw existingError

      // Backfill softap_password for rows created by older revisions of this
      // function (column was added 2026-04-30, but rows pre-existed). Generate
      // once and store; subsequent retries return the same value.
      let softapPassword = existing.softap_password as string | null
      if (!softapPassword) {
        softapPassword = generateSoftApPassword()
        const { error: updErr } = await adminClient
          .from('embeddeds')
          .update({ softap_password: softapPassword })
          .eq('id', existing.id)
        if (updErr) throw updErr
      }

      return new Response(
        JSON.stringify({
          company_id: token.company_id,
          device_id: existing.id,
          passkey: existing.passkey,
          softap_password: softapPassword,
          mqtt_host: Deno.env.get('MQTT_PUBLIC_HOST') ?? 'mqtt.vmflow.xyz',
          mqtt_port: Deno.env.get('MQTT_PUBLIC_PORT') ?? '1883',
          mqtt_user: 'vmflow',
          mqtt_pass: 'vmflow',
        }),
        { status: 200, headers: { 'Content-Type': 'application/json' } }
      )
    }
```

- [ ] **Step 2.4: Smoke-test end-to-end manually**

Restart edge runtime if needed (`supabase functions serve --no-verify-jwt claim-device &`), then:

```bash
# Insert a token via Studio or psql first, replace below with real value
SHORT_CODE="ABCD1234"
curl -sS -X POST http://127.0.0.1:54321/functions/v1/claim-device \
  -H "Content-Type: application/json" \
  -d "{\"short_code\":\"$SHORT_CODE\",\"mac_address\":\"aa:bb:cc:11:22:33\"}" \
  | jq .
```

Expected: response body includes `softap_password: "<12 chars>"`.

```bash
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
  -c "SELECT mac_address, softap_password FROM embeddeds ORDER BY created_at DESC LIMIT 1;"
```

Expected: row has the same `softap_password` value as the response.

Re-call the same `curl` (idempotent retry):

```bash
curl -sS -X POST http://127.0.0.1:54321/functions/v1/claim-device \
  -H "Content-Type: application/json" \
  -d "{\"short_code\":\"$SHORT_CODE\",\"mac_address\":\"aa:bb:cc:11:22:33\"}" \
  | jq .
```

Expected: identical `softap_password` (NOT a new value — the device's stored password must remain valid).

- [ ] **Step 2.5: Commit**

```bash
git add Docker/supabase/functions/claim-device/index.ts
git commit -m "feat(claim-device): generate per-device softap_password, return in response"
```

### Task 3: Deno tests for `claim-device`

**Files:**
- Create: `Docker/supabase/functions/claim-device/claim-device.test.ts`

- [ ] **Step 3.1: Write the test file**

```typescript
import { assertEquals, assertMatch, assertNotEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"
import { generateSoftApPassword } from "./index.ts"

Deno.test("generateSoftApPassword: length 12", () => {
  for (let i = 0; i < 100; i++) {
    assertEquals(generateSoftApPassword().length, 12)
  }
})

Deno.test("generateSoftApPassword: alphabet has no confusable chars", () => {
  // Reject if any of 0, O, 1, l, I appears in 1000 generations.
  for (let i = 0; i < 1000; i++) {
    const pwd = generateSoftApPassword()
    assertMatch(pwd, /^[ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789]+$/)
  }
})

Deno.test("generateSoftApPassword: low collision rate (sanity)", () => {
  const seen = new Set<string>()
  for (let i = 0; i < 1000; i++) {
    seen.add(generateSoftApPassword())
  }
  // 1000 draws from a ~70-bit space — collisions astronomically unlikely.
  assertEquals(seen.size, 1000)
})

Deno.test("generateSoftApPassword: independent calls produce different values", () => {
  // Catches a regression where someone caches the result accidentally.
  assertNotEquals(generateSoftApPassword(), generateSoftApPassword())
})
```

- [ ] **Step 3.2: Run the test**

```bash
cd Docker/supabase/functions/claim-device
deno test --allow-all claim-device.test.ts
```

Expected: `ok | 4 passed | 0 failed`.

- [ ] **Step 3.3: Commit**

```bash
git add Docker/supabase/functions/claim-device/claim-device.test.ts
git commit -m "test(claim-device): cover SoftAP password generator output"
```

---

## Chunk 2: Firmware — SSID compute + NVS-or-default + claim-response handling

### Task 4: Replace `AP_SSID`/`AP_PASS` macros with helper functions

**Files:**
- Modify: `mdb-slave-esp32s3/main/webui_server.h`
- Modify: `mdb-slave-esp32s3/main/webui_server.c:575-589` (`start_softap`)
- Modify: `mdb-slave-esp32s3/main/webui_server.c:433` (`wifi_scan_get_handler` self-filter)

- [ ] **Step 4.1: Update the header**

Replace the entire body of `webui_server.h`:

```c
#ifndef WEBUI_SERVER_H
#define WEBUI_SERVER_H

#include <stddef.h>
#include "esp_err.h"

/* SoftAP credential helpers.
 *
 * SSID is computed deterministically from the WIFI_IF_STA MAC at every boot
 * (no NVS storage). Format: "VMflow-XXXXXX" where XXXXXX = last 3 bytes of
 * the MAC in uppercase hex.
 *
 * Password comes from NVS namespace "vmflow", key "softap_pwd", written by
 * provision_claim_task after a successful claim. If the key is missing,
 * empty, or shorter than 8 chars (WPA2 PSK minimum), the helper writes an
 * empty string into out and start_softap brings the AP up as WIFI_AUTH_OPEN.
 * The firmware never generates a random password itself — that is the
 * backend's job at claim time.
 *
 * Spec: docs/superpowers/specs/2026-04-30-softap-per-device-credentials-design.md
 */

#define SOFTAP_SSID_MAX        32   /* "VMflow-XXXXXX" + NUL fits comfortably */
#define SOFTAP_PWD_MAX         16

/** Fill `out` with "VMflow-XXXXXX" where XXXXXX is the last 3 bytes of the
 *  STA MAC in uppercase hex. */
esp_err_t softap_get_ssid(char *out, size_t out_len);

/** Read NVS "softap_pwd". On success out contains either a WPA2-valid
 *  password (≥8 chars NUL-terminated) or the empty string (signal: open AP).
 *  Always returns ESP_OK; underlying NVS errors are absorbed into the
 *  empty-string fallback so the AP always comes up in some form. */
esp_err_t softap_get_password(char *out, size_t out_len);

void start_softap(void);
void start_rest_server(void);
void stop_rest_server(void);

void start_dns_server(void);
void stop_dns_server(void);

#endif
```

- [ ] **Step 4.2: Implement the helpers in `webui_server.c`**

Locate the `/* ---------- SoftAP ---------- */` divider near line 575. Insert these helpers BEFORE the existing `start_softap` function:

```c
esp_err_t softap_get_ssid(char *out, size_t out_len) {
    if (!out || out_len < 14) return ESP_ERR_INVALID_ARG;  /* "VMflow-AABBCC" + NUL = 14 */
    uint8_t mac[6];
    esp_err_t err = esp_wifi_get_mac(WIFI_IF_STA, mac);
    if (err != ESP_OK) return err;
    snprintf(out, out_len, "VMflow-%02X%02X%02X", mac[3], mac[4], mac[5]);
    return ESP_OK;
}

esp_err_t softap_get_password(char *out, size_t out_len) {
    if (!out || out_len < 9) return ESP_ERR_INVALID_ARG;  /* WPA2 PSK min is 8 + NUL */
    out[0] = '\0';  /* default: empty string ⇒ open AP */

    nvs_handle_t h;
    esp_err_t err = nvs_open("vmflow", NVS_READONLY, &h);
    if (err == ESP_OK) {
        size_t len = out_len;
        err = nvs_get_str(h, "softap_pwd", out, &len);
        nvs_close(h);
        if (err != ESP_OK || strlen(out) < 8) {
            /* Missing, too short, or read error — fall through to empty.
             * This is the path taken before the device is claimed, and on
             * existing already-claimed devices that haven't been re-claimed
             * since OTA. start_softap brings up the AP as open. */
            out[0] = '\0';
        }
    }
    return ESP_OK;
}
```

Add the necessary includes near the top of `webui_server.c` if not already present:

```c
#include "esp_wifi.h"
#include "nvs.h"     /* probably already there */
#include <string.h>  /* probably already there */
```

(Inspect existing includes first; only add what's actually missing.)

- [ ] **Step 4.3: Update `start_softap` to use the helpers**

Replace the body of `start_softap` (lines 577-589):

```c
void start_softap(void) {
    char ssid[SOFTAP_SSID_MAX];
    char pwd[SOFTAP_PWD_MAX];

    if (softap_get_ssid(ssid, sizeof(ssid)) != ESP_OK) {
        ESP_LOGE(TAG, "SoftAP SSID fetch failed; using static fallback");
        snprintf(ssid, sizeof(ssid), "VMflow");
    }
    softap_get_password(pwd, sizeof(pwd));  /* never errors; empty pwd ⇒ open */

    bool open = (pwd[0] == '\0');

    wifi_config_t wifi_config = {
        .ap = {
            .ssid_len       = strlen(ssid),
            .max_connection = 4,
            .authmode       = open ? WIFI_AUTH_OPEN : WIFI_AUTH_WPA_WPA2_PSK,
        },
    };
    strncpy((char *)wifi_config.ap.ssid, ssid, sizeof(wifi_config.ap.ssid));
    if (!open) {
        strncpy((char *)wifi_config.ap.password, pwd, sizeof(wifi_config.ap.password));
    }

    esp_err_t err = esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    ESP_LOGI(TAG, "SoftAP config set (SSID=\"%s\" auth=%s) → %s",
             ssid, open ? "OPEN" : "WPA2", esp_err_to_name(err));
}
```

- [ ] **Step 4.4: Fix the WiFi-scan self-filter (line 433)**

The original code is `if (strcmp(ssid, AP_SSID) == 0) continue;` and is responsible for hiding the device's own SoftAP from the captive portal's WiFi-scan list. Compute the SSID once before the loop:

```c
    /* Hide our own SoftAP from the scan results — the user is already
     * connected to it, listing it would be confusing. */
    char own_ssid[SOFTAP_SSID_MAX] = {0};
    softap_get_ssid(own_ssid, sizeof(own_ssid));

    /* … existing loop … */
        if (strcmp(ssid, own_ssid) == 0) continue;
    /* … */
```

- [ ] **Step 4.5: Build the firmware**

```bash
cd mdb-slave-esp32s3
. $IDF_PATH/export.sh
idf.py build
```

Expected: clean build, no warnings about `AP_SSID`/`AP_PASS` undefined. If a stray reference exists, fix it.

- [ ] **Step 4.6: Commit**

```bash
git add mdb-slave-esp32s3/main/webui_server.h mdb-slave-esp32s3/main/webui_server.c
git commit -m "feat(firmware): per-device SoftAP SSID; WPA2 if NVS password set, else open AP"
```

### Task 5: Persist `softap_password` from claim response into NVS

**Files:**
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:2362-2378` (WiFi response-handling block)
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c:2505-2521` (cellular response-handling block)

The two blocks are near-duplicates — they each parse the response JSON, write fields to NVS, and erase `prov_code`. Extend both to also persist `softap_password` when present.

- [ ] **Step 5.1: Locate both response-handling blocks**

```bash
grep -n 'nvs_set_str(h, "company_id"' mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
```

Expected: two matches (~line 2364 for WiFi, ~line 2507 for cellular). Verify both are inside an `if (nvs_open(... NVS_READWRITE, &h) == ESP_OK)` block followed by `nvs_erase_key(h, "prov_code")` and `nvs_commit(h)`.

- [ ] **Step 5.2: Extend the WiFi-path block (around line 2371)**

Inside the `if (nvs_open(...) == ESP_OK)` block, AFTER the existing `mqtt_port` extraction and BEFORE `nvs_erase_key(h, "prov_code")`, insert:

```c
                        cJSON *j_softap = cJSON_GetObjectItem(root, "softap_password");
                        if (j_softap && cJSON_IsString(j_softap) && strlen(j_softap->valuestring) >= 8) {
                            nvs_set_str(h, "softap_pwd", j_softap->valuestring);
                            ESP_LOGI(TAG, "PROV: stored backend-assigned SoftAP password");
                        }
```

- [ ] **Step 5.3: Mirror the change into the cellular-path block (around line 2515)**

Same insertion, same position relative to the surrounding lines. Both blocks are structurally identical; the only difference is the function name in the surrounding logging.

- [ ] **Step 5.4: Build the firmware**

```bash
cd mdb-slave-esp32s3
. $IDF_PATH/export.sh
idf.py build
```

Expected: clean build.

- [ ] **Step 5.5: Commit**

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c
git commit -m "feat(firmware): persist softap_password from claim response into NVS"
```

---

## Chunk 3: Frontend — SSID helper, modal, page integration

### Task 6: Frontend helpers + Vitest

**Files:**
- Create: `management-frontend/app/lib/softap.ts`
- Create: `management-frontend/app/lib/__tests__/softap.test.ts`

- [ ] **Step 6.1: Write the failing test first**

```typescript
// management-frontend/app/lib/__tests__/softap.test.ts
import { describe, it, expect } from 'vitest'
import { computeSoftApSsid, formatWifiQrPayload } from '../softap'

describe('computeSoftApSsid', () => {
  it('formats last 3 bytes uppercase from a colon-separated MAC', () => {
    expect(computeSoftApSsid('f4:12:fa:a1:b2:c3')).toBe('VMflow-A1B2C3')
  })
  it('handles dash-separated MACs', () => {
    expect(computeSoftApSsid('F4-12-FA-A1-B2-C3')).toBe('VMflow-A1B2C3')
  })
  it('handles bare-hex MACs (no separators)', () => {
    expect(computeSoftApSsid('f412faa1b2c3')).toBe('VMflow-A1B2C3')
  })
  it('falls back to a placeholder when MAC is null', () => {
    expect(computeSoftApSsid(null)).toBe('VMflow-?')
  })
  it('falls back when MAC is malformed', () => {
    expect(computeSoftApSsid('not-a-mac')).toBe('VMflow-?')
    expect(computeSoftApSsid('aa:bb:cc')).toBe('VMflow-?')  // too short
  })
})

describe('formatWifiQrPayload', () => {
  it('produces a standard WIFI: URI', () => {
    expect(formatWifiQrPayload('VMflow-A1B2C3', 'AbCd2EfG3HjK'))
      .toBe('WIFI:T:WPA;S:VMflow-A1B2C3;P:AbCd2EfG3HjK;;')
  })
  it('escapes special characters in the password per WPA QR spec', () => {
    expect(formatWifiQrPayload('VMflow-X', 'a;b\\c"d:e,f'))
      .toBe('WIFI:T:WPA;S:VMflow-X;P:a\\;b\\\\c\\"d\\:e\\,f;;')
  })
})
```

- [ ] **Step 6.2: Run the test, verify it fails**

```bash
cd management-frontend
npx vitest run app/lib/__tests__/softap.test.ts
```

Expected: FAIL — `computeSoftApSsid` not exported.

- [ ] **Step 6.3: Implement the helpers**

```typescript
// management-frontend/app/lib/softap.ts

/**
 * Compute the SoftAP SSID for a device given its MAC address.
 * Mirrors firmware logic in mdb-slave-esp32s3/main/webui_server.c::softap_get_ssid.
 *
 * Format: "VMflow-XXXXXX" where XXXXXX is the last 3 bytes of the MAC in
 * uppercase hex. Falls back to "VMflow-?" if the MAC is missing or malformed —
 * used as a hint that the device hasn't reported its MAC yet (claim hasn't
 * completed).
 */
export function computeSoftApSsid(mac: string | null | undefined): string {
  if (!mac) return 'VMflow-?'
  const hex = mac.replace(/[^0-9a-fA-F]/g, '').toUpperCase()
  if (hex.length !== 12) return 'VMflow-?'
  return `VMflow-${hex.slice(6, 12)}`
}

/**
 * Build a WPA WiFi-QR payload per the de-facto MeCard-style standard supported
 * by iOS Camera, Android Camera, and most QR scanner apps. Special chars in
 * SSID/password are escaped with a backslash per the standard.
 */
export function formatWifiQrPayload(ssid: string, password: string): string {
  const escape = (s: string) => s.replace(/[\\;,":]/g, c => `\\${c}`)
  return `WIFI:T:WPA;S:${escape(ssid)};P:${escape(password)};;`
}
```

- [ ] **Step 6.4: Run the test, verify it passes**

```bash
cd management-frontend
npx vitest run app/lib/__tests__/softap.test.ts
```

Expected: PASS, all 7 tests green.

- [ ] **Step 6.5: Commit**

```bash
git add management-frontend/app/lib/softap.ts management-frontend/app/lib/__tests__/softap.test.ts
git commit -m "feat(frontend): add computeSoftApSsid + formatWifiQrPayload helpers"
```

### Task 7: Build `SoftApCredentialsModal.vue`

**Files:**
- Create: `management-frontend/app/components/SoftApCredentialsModal.vue`

- [ ] **Step 7.1: Create the component**

```vue
<script setup lang="ts">
import QRCode from 'qrcode'
import { computeSoftApSsid, formatWifiQrPayload } from '@/lib/softap'

interface Props {
  open: boolean
  device: {
    id: string
    mac_address: string | null
    subdomain: number | null
    softap_password: string | null
  } | null
}

const props = defineProps<Props>()
const emit = defineEmits<{ (e: 'close'): void }>()

const { t } = useI18n()

const ssid = computed(() => computeSoftApSsid(props.device?.mac_address ?? null))
// "Open AP" state: device hasn't been claimed against the new backend yet, so
// no password has been assigned. The frontend treats this as a distinct state
// (not "the password is empty string") so the UI can render guidance instead
// of trying to copy/show an empty string.
const isOpenAp = computed(() => !props.device?.softap_password)
const password = computed(() => props.device?.softap_password ?? '')

const passwordVisible = ref(false)
const copied = ref(false)
const qrDataUrl = ref('')

watch(
  () => [props.open, ssid.value, password.value, isOpenAp.value],
  async ([isOpen, , , openMode]) => {
    if (!isOpen) {
      qrDataUrl.value = ''
      return
    }
    // QR encodes T:nopass for open networks (per the WPA QR de-facto spec).
    const payload = openMode
      ? `WIFI:T:nopass;S:${ssid.value};;`
      : formatWifiQrPayload(ssid.value, password.value)
    qrDataUrl.value = await QRCode.toDataURL(payload, { width: 240, margin: 2 })
  },
  { immediate: true },
)

watch(() => props.open, (o) => {
  if (!o) {
    passwordVisible.value = false
    copied.value = false
  }
})

async function copyPassword() {
  if (!password.value) return
  try {
    await navigator.clipboard.writeText(password.value)
    copied.value = true
    setTimeout(() => { copied.value = false }, 1500)
  } catch {
    // Clipboard API unavailable (HTTP, no permission). Silent.
  }
}
</script>

<template>
  <AppModal :open="open" :title="t('softap.title')" @close="emit('close')">
    <div v-if="!device" class="text-sm text-muted-foreground">
      {{ t('common.loading') }}
    </div>
    <div v-else class="space-y-4">
      <!-- Open-AP banner -->
      <div
        v-if="isOpenAp"
        class="rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-xs text-amber-700 dark:text-amber-300"
      >
        <p class="font-medium">{{ t('softap.openAp') }}</p>
        <p class="mt-1">{{ t('softap.openApHint') }}</p>
      </div>

      <!-- SSID -->
      <div>
        <p class="text-xs font-medium text-muted-foreground">{{ t('softap.ssid') }}</p>
        <p class="mt-1 font-mono text-base">{{ ssid }}</p>
      </div>

      <!-- Password (only when assigned) -->
      <div v-if="!isOpenAp">
        <p class="text-xs font-medium text-muted-foreground">{{ t('softap.password') }}</p>
        <div class="mt-1 flex items-center gap-2">
          <p class="flex-1 font-mono text-base">
            <template v-if="passwordVisible">{{ password }}</template>
            <template v-else>••••••••••••</template>
          </p>
          <button
            type="button"
            class="inline-flex h-7 items-center rounded-md border px-2 text-xs hover:bg-muted"
            @click="passwordVisible = !passwordVisible"
          >
            {{ passwordVisible ? t('softap.hide') : t('softap.reveal') }}
          </button>
          <button
            type="button"
            class="inline-flex h-7 items-center rounded-md border px-2 text-xs hover:bg-muted"
            @click="copyPassword"
          >
            {{ copied ? t('softap.copied') : t('softap.copy') }}
          </button>
        </div>
      </div>

      <!-- QR (always rendered — works for both open and WPA2) -->
      <div v-if="qrDataUrl" class="flex flex-col items-center gap-2 pt-2">
        <img :src="qrDataUrl" :alt="ssid" class="rounded-md border bg-white p-2" width="240" height="240" />
        <p class="text-xs text-muted-foreground">{{ t('softap.qrHelp') }}</p>
      </div>
    </div>
  </AppModal>
</template>
```

Note the modal renders a QR even for open-AP devices — the WiFi-QR `T:nopass` form joins networks without a password, saving the technician an extra tap.

- [ ] **Step 7.2: Build the frontend, confirm no errors**

```bash
cd management-frontend
npm run build
```

Expected: build succeeds. If it complains about `AppModal` import path, inspect a sibling component (e.g. `MachineSettingsModal.vue`) for the canonical import pattern and adjust.

- [ ] **Step 7.3: Commit**

```bash
git add management-frontend/app/components/SoftApCredentialsModal.vue
git commit -m "feat(frontend): SoftApCredentialsModal showing SSID/password/QR"
```

### Task 8: Wire modal into `/devices` and update provisioning instructions

**Files:**
- Modify: `management-frontend/app/pages/devices/index.vue`

- [ ] **Step 8.1: Add `softap_password` to the `EmbeddedDevice` interface and the SELECT**

In the `EmbeddedDevice` interface (around line 44):

```typescript
interface EmbeddedDevice {
  id: string
  created_at: string
  subdomain: number
  mac_address: string | null
  status: string
  status_at: string
  firmware_version: string | null
  firmware_build_date: string | null
  mdb_diagnostics: Record<string, any> | null
  softap_password: string | null   // NEW
  machine_name: string | null
  machine_id: string | null
}
```

In `fetchDevices` (around line 67):

```typescript
    const { data, error } = await supabase
      .from('embeddeds')
      .select('id, created_at, subdomain, mac_address, status, status_at, firmware_version, firmware_build_date, mdb_diagnostics, softap_password')
      .order('created_at', { ascending: false })
```

- [ ] **Step 8.2: Add modal state**

Near the other modal state declarations (around line 215, where `deleteModal` is declared):

```typescript
// ── SoftAP credentials modal ────────────────────────────────────────────
const softapModalOpen = ref(false)
const softapModalDevice = ref<EmbeddedDevice | null>(null)

function openSoftapModal(device: EmbeddedDevice) {
  softapModalDevice.value = device
  softapModalOpen.value = true
}

function closeSoftapModal() {
  softapModalOpen.value = false
  softapModalDevice.value = null
}
```

- [ ] **Step 8.3: Add the trigger button to each row**

Locate the existing row-actions cell (search for the row that contains `openDeleteModal(device)` — desktop table layout, then mobile card layout).

Insert a "WiFi" icon button BEFORE the delete button in BOTH layouts:

```vue
<button
  v-if="isAdmin"
  type="button"
  class="inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground"
  :title="t('softap.title')"
  @click.stop="openSoftapModal(device)"
>
  <svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <path d="M5 12.55a11 11 0 0 1 14.08 0"/>
    <path d="M1.42 9a16 16 0 0 1 21.16 0"/>
    <path d="M8.53 16.11a6 6 0 0 1 6.95 0"/>
    <line x1="12" x2="12.01" y1="20" y2="20"/>
  </svg>
</button>
```

- [ ] **Step 8.4: Mount the modal at the bottom of the template**

Add the SoftAP modal alongside the existing modals (e.g. right after the `<AppModal v-model:open="showModal">` block):

```vue
<SoftApCredentialsModal
  :open="softapModalOpen"
  :device="softapModalDevice"
  @close="closeSoftapModal"
/>
```

- [ ] **Step 8.5: Update the legacy provisioning instructions**

Find the line with `t('devices.step1', ...)` (around line 547). Replace the entire `<li>` block with:

```vue
<li class="flex gap-2">
  <span class="flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-primary text-xs font-medium text-primary-foreground">1</span>
  <span>{{ t('devices.step1') }}</span>
</li>
```

The new `t('devices.step1')` text reads naturally without HTML interpolation (it now references the sticker rather than naming the literal credentials — i18n is updated in Task 9).

- [ ] **Step 8.6: Build, confirm no type errors**

```bash
cd management-frontend
npm run build
```

- [ ] **Step 8.7: Commit**

```bash
git add management-frontend/app/pages/devices/index.vue
git commit -m "feat(frontend): SoftAP credentials button + modal on /devices"
```

### Task 9: Update i18n strings

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`

- [ ] **Step 9.1: Update `en.json`**

In the `devices` block, replace `step1` and remove `wifiNetwork`/`wifiPassword`:

```json
    "step1": "Connect your phone to the device's WiFi network — pick the network starting with 'VMflow-'. Fresh devices have an open WiFi (no password needed); claimed devices show their password in the management UI under their device entry.",
```

(Delete the `"wifiNetwork": "VMflow",` and `"wifiPassword": "12345678",` lines.)

Add a new top-level `softap` block (alphabetically near `time`):

```json
  "softap": {
    "title": "WiFi access (SoftAP)",
    "ssid": "Network name (SSID)",
    "password": "Password",
    "reveal": "Show",
    "hide": "Hide",
    "copy": "Copy",
    "copied": "Copied!",
    "openAp": "This device's SoftAP is currently open (no password).",
    "openApHint": "Factory-reset the device and re-claim it from the management UI to assign a unique per-device password.",
    "qrHelp": "Scan with your phone's camera to connect automatically."
  },
```

- [ ] **Step 9.2: Update `de.json` with mirror keys**

```json
    "step1": "Verbinde dein Handy mit dem WLAN des Geräts — wähle das Netzwerk mit dem Präfix 'VMflow-'. Neue Geräte haben ein offenes WLAN (kein Passwort); registrierte Geräte zeigen ihr Passwort in der Management-UI im jeweiligen Geräte-Eintrag.",
```

(Delete the `wifiNetwork` and `wifiPassword` lines.)

Add the `softap` block:

```json
  "softap": {
    "title": "WLAN-Zugang (SoftAP)",
    "ssid": "Netzwerkname (SSID)",
    "password": "Passwort",
    "reveal": "Anzeigen",
    "hide": "Verbergen",
    "copy": "Kopieren",
    "copied": "Kopiert!",
    "openAp": "Der SoftAP dieses Geräts ist derzeit offen (kein Passwort).",
    "openApHint": "Den Factory-Reset auslösen und das Gerät neu claimen, um ein gerätespezifisches Passwort zuzuweisen.",
    "qrHelp": "Mit der Handy-Kamera scannen, um automatisch zu verbinden."
  },
```

- [ ] **Step 9.3: Verify both JSON files parse**

```bash
cd management-frontend
node -e "JSON.parse(require('fs').readFileSync('i18n/locales/en.json'))" && echo OK
node -e "JSON.parse(require('fs').readFileSync('i18n/locales/de.json'))" && echo OK
```

Both should print `OK`.

- [ ] **Step 9.4: Build**

```bash
cd management-frontend
npm run build
```

- [ ] **Step 9.5: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json
git commit -m "i18n: add softap.* keys, drop hardcoded wifiNetwork/wifiPassword"
```

### Task 10: Wire modal into `/machines/[id]`

**Files:**
- Modify: `management-frontend/app/pages/machines/[id].vue`

- [ ] **Step 10.1: Locate the device-info area**

```bash
cd management-frontend
grep -n 'mac_address\|firmware_version\|embedded' app/pages/machines/\[id\].vue | head -20
```

This identifies the section showing the linked embedded device's details. The new "WiFi" button goes there.

- [ ] **Step 10.2: Add `softap_password` to the relevant query**

Find the `supabase.from('embeddeds').select(...)` call (or the machine-with-embedded join) and append `softap_password` to the column list. Extend each occurrence.

- [ ] **Step 10.3: Add modal state and trigger button**

Mirror the `/devices` integration: import `SoftApCredentialsModal`, add `softapModalOpen`/`softapModalDevice` state, add a small "WiFi" button in the device-info card area, mount the modal in the template.

The shape passed to the modal must match the component prop interface:
```ts
{ id, mac_address, subdomain, softap_password }
```

- [ ] **Step 10.4: Build**

```bash
cd management-frontend
npm run build
```

- [ ] **Step 10.5: Commit**

```bash
git add management-frontend/app/pages/machines/\[id\].vue
git commit -m "feat(frontend): SoftAP credentials access from machine detail page"
```

---

## Chunk 4: Auto-migration — sync endpoint + firmware sync task

### Task 11: New `sync-softap-password` Edge Function

**Files:**
- Create: `Docker/supabase/functions/sync-softap-password/deno.json`
- Create: `Docker/supabase/functions/sync-softap-password/index.ts`
- Create: `Docker/supabase/functions/sync-softap-password/sync-softap-password.test.ts`
- Modify: `Docker/supabase/config.toml` (add `[functions.sync-softap-password]` block)

The endpoint authenticates the device via HMAC-SHA256 over `device_id|mac_address|timestamp`, signed with the existing `passkey`. It looks up the row, generates a `softap_password` if missing, and returns it. Idempotent on retry.

- [ ] **Step 11.1: Create the deno.json**

```json
{
  "imports": {
    "https://esm.sh/@supabase/supabase-js@2": "https://esm.sh/@supabase/supabase-js@2"
  }
}
```

- [ ] **Step 11.2: Create `index.ts`**

```typescript
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { generateSoftApPassword } from '../claim-device/index.ts'

const TIMESTAMP_TOLERANCE_S = 60

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

/** HMAC-SHA256(key, message) → lowercase hex. */
async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  const cryptoKey = await crypto.subtle.importKey(
    'raw', enc.encode(key),
    { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign']
  )
  const sig = await crypto.subtle.sign('HMAC', cryptoKey, enc.encode(message))
  return Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

/** Constant-time hex string comparison. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  try {
    const body = await req.json()
    const { device_id, mac_address, timestamp, signature } = body

    if (typeof device_id !== 'string' || !device_id ||
        typeof mac_address !== 'string' || !mac_address ||
        typeof timestamp !== 'number' ||
        typeof signature !== 'string' || !signature) {
      return jsonResponse({ error: 'missing or malformed required field' }, 400)
    }

    const now = Math.floor(Date.now() / 1000)
    if (Math.abs(now - timestamp) > TIMESTAMP_TOLERANCE_S) {
      return jsonResponse({ error: 'timestamp out of window' }, 401)
    }

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: row, error: rowErr } = await adminClient
      .from('embeddeds')
      .select('id, mac_address, passkey, softap_password')
      .eq('id', device_id)
      .maybeSingle()

    if (rowErr) throw rowErr
    if (!row) return jsonResponse({ error: 'device not found' }, 401)
    if (row.mac_address?.toLowerCase() !== mac_address.toLowerCase()) {
      return jsonResponse({ error: 'mac mismatch' }, 401)
    }

    const expected = await hmacSha256Hex(
      row.passkey,
      `${device_id}|${mac_address}|${timestamp}`,
    )
    if (!timingSafeEqual(expected, signature.toLowerCase())) {
      return jsonResponse({ error: 'signature mismatch' }, 401)
    }

    let softapPassword = row.softap_password as string | null
    if (!softapPassword) {
      softapPassword = generateSoftApPassword()
      const { error: updErr } = await adminClient
        .from('embeddeds')
        .update({ softap_password: softapPassword })
        .eq('id', row.id)
      if (updErr) throw updErr
    }

    return jsonResponse({ softap_password: softapPassword }, 200)
  } catch (err) {
    return jsonResponse({ error: (err as Error)?.message ?? 'internal error' }, 500)
  }
})
```

- [ ] **Step 11.3: Register the function in `config.toml`**

Add the following block in `Docker/supabase/config.toml` next to the other `[functions.*]` entries:

```toml
[functions.sync-softap-password]
verify_jwt = false
import_map = "./functions/sync-softap-password/deno.json"
```

(`verify_jwt = false` because the function does its own HMAC-based auth — same pattern as `claim-device`.)

- [ ] **Step 11.4: Create the test file**

```typescript
import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"

const FUNC_URL = "http://127.0.0.1:54321/functions/v1/sync-softap-password"

async function hmac(key: string, msg: string): Promise<string> {
  const enc = new TextEncoder()
  const k = await crypto.subtle.importKey(
    "raw", enc.encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  )
  const s = await crypto.subtle.sign("HMAC", k, enc.encode(msg))
  return Array.from(new Uint8Array(s))
    .map(b => b.toString(16).padStart(2, "0")).join("")
}

// These tests assume a dev edge runtime is already up via `supabase functions serve`
// AND the test fixture row in `embeddeds` exists with a known passkey.
// Replace DEVICE_ID, MAC, PASSKEY with actual values from your dev DB before running.

const DEVICE_ID = Deno.env.get("TEST_DEVICE_ID") ?? ""
const MAC = Deno.env.get("TEST_DEVICE_MAC") ?? ""
const PASSKEY = Deno.env.get("TEST_DEVICE_PASSKEY") ?? ""

const haveFixture = DEVICE_ID && MAC && PASSKEY

Deno.test({
  name: "valid signature → 200 with softap_password",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000)
    const sig = await hmac(PASSKEY, `${DEVICE_ID}|${MAC}|${ts}`)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: MAC, timestamp: ts, signature: sig }),
    })
    assertEquals(res.status, 200)
    const data = await res.json()
    assertEquals(typeof data.softap_password, "string")
    assertEquals(data.softap_password.length, 12)
  },
})

Deno.test({
  name: "wrong signature → 401",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: MAC, timestamp: ts, signature: "deadbeef".repeat(8) }),
    })
    assertEquals(res.status, 401)
  },
})

Deno.test({
  name: "stale timestamp → 401",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000) - 3600
    const sig = await hmac(PASSKEY, `${DEVICE_ID}|${MAC}|${ts}`)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: MAC, timestamp: ts, signature: sig }),
    })
    assertEquals(res.status, 401)
  },
})

Deno.test({
  name: "mac mismatch → 401",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000)
    const wrongMac = "00:00:00:00:00:00"
    const sig = await hmac(PASSKEY, `${DEVICE_ID}|${wrongMac}|${ts}`)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: wrongMac, timestamp: ts, signature: sig }),
    })
    assertEquals(res.status, 401)
  },
})

Deno.test({
  name: "missing field → 400",
  fn: async () => {
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: "x" }),
    })
    assertEquals(res.status, 400)
  },
})
```

- [ ] **Step 11.5: Restart edge runtime + run tests**

```bash
cd Docker/supabase
# Restart functions serve to pick up new function (if running)
# Set fixture env vars from a real dev row:
psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
  -c "SELECT id, mac_address, passkey FROM embeddeds LIMIT 1;"
# Export the values:
export TEST_DEVICE_ID=...
export TEST_DEVICE_MAC=...
export TEST_DEVICE_PASSKEY=...

cd functions/sync-softap-password
deno test --allow-all sync-softap-password.test.ts
```

Expected: at least the "missing field → 400" test passes unconditionally; the others pass when `TEST_DEVICE_*` env vars are set.

- [ ] **Step 11.6: Smoke-test idempotency manually**

Hit the endpoint twice with valid signatures (~5 seconds apart). Both responses should contain the **same** `softap_password`. Then `psql` to confirm the column was set (or unchanged, if it had a value).

- [ ] **Step 11.7: Commit**

```bash
git add Docker/supabase/functions/sync-softap-password Docker/supabase/config.toml
git commit -m "feat(sync-softap-password): HMAC-authenticated re-sync endpoint for already-claimed devices"
```

### Task 12: Firmware boot-time sync task for already-claimed devices

**Files:**
- Modify: `mdb-slave-esp32s3/main/mdb-slave-esp32s3.c` (add `softap_sync_task` definition + spawn from `UPLINK_UP` handler)
- Modify: `mdb-slave-esp32s3/main/CMakeLists.txt` (only if `mbedtls` isn't already in `REQUIRES`; check first)

The task spawns when `device_id` + `passkey` + `srv_url` are in NVS but `softap_pwd` is missing. Same retry pattern as `provision_claim_task` (3 attempts, exponential backoff). On success: NVS write + `start_softap()` reload. The new SoftAP config takes effect immediately (deauths existing AP clients).

- [ ] **Step 12.1: Verify `mbedtls` is available**

```bash
grep -E 'REQUIRES|mbedtls' mdb-slave-esp32s3/main/CMakeLists.txt
```

`mbedtls` is pulled in transitively via `esp-tls` for TLS support. If it's not directly declared in `REQUIRES`, add it:

```cmake
idf_component_register(SRCS ...
                       INCLUDE_DIRS ...
                       REQUIRES ... mbedtls ...)
```

(Only edit if the include `#include "mbedtls/md.h"` later fails to compile.)

- [ ] **Step 12.2: Add the sync-task implementation in `mdb-slave-esp32s3.c`**

Insert below the `provision_claim_task` definition (after the closing brace of that function, around line 2730):

```c
/* ============================================================================
 * SoftAP password sync task — runs once per boot for already-claimed devices
 * that don't yet have softap_pwd in NVS. Posts an HMAC-authenticated request
 * to /functions/v1/sync-softap-password, writes the returned password to NVS,
 * and reloads the SoftAP config in place.
 * ============================================================================ */

#include "mbedtls/md.h"

static bool s_softap_sync_running = false;
static bool s_softap_sync_done    = false;

#define SOFTAP_SYNC_MAX_ATTEMPTS  3
static const int SOFTAP_SYNC_RETRY_DELAYS_S[] = { 5, 30 };

static void compute_softap_sync_signature(const char *passkey,
                                          const char *device_id,
                                          const char *mac_str,
                                          uint32_t timestamp,
                                          char *out_hex,  /* 65 bytes: 64 hex + NUL */
                                          size_t out_hex_len)
{
    char message[160];
    snprintf(message, sizeof(message), "%s|%s|%lu",
             device_id, mac_str, (unsigned long)timestamp);

    uint8_t digest[32];
    const mbedtls_md_info_t *md = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(md,
                    (const uint8_t *)passkey, strlen(passkey),
                    (const uint8_t *)message, strlen(message),
                    digest);

    if (out_hex_len < 65) { out_hex[0] = '\0'; return; }
    static const char HEX[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) {
        out_hex[i * 2]     = HEX[digest[i] >> 4];
        out_hex[i * 2 + 1] = HEX[digest[i] & 0x0F];
    }
    out_hex[64] = '\0';
}

void softap_sync_task(void *arg) {
    if (s_softap_sync_running || s_softap_sync_done) {
        ESP_LOGI(TAG, "SOFTAP SYNC: already running or done, skipping");
        vTaskDelete(NULL);
        return;
    }
    s_softap_sync_running = true;

    /* Read NVS prerequisites. Bail if anything missing — the device is in
     * an in-between state we don't try to repair from here. */
    char device_id[64] = {0};
    char passkey[32]   = {0};
    char srv_url[128]  = {0};
    char softap_pwd_existing[16] = {0};

    nvs_handle_t h;
    if (nvs_open("vmflow", NVS_READONLY, &h) != ESP_OK) {
        ESP_LOGW(TAG, "SOFTAP SYNC: NVS open failed");
        goto done;
    }
    size_t l;
    l = sizeof(device_id);            nvs_get_str(h, "device_id", device_id, &l);
    l = sizeof(passkey);              nvs_get_str(h, "passkey",   passkey,   &l);
    l = sizeof(srv_url);              nvs_get_str(h, "srv_url",   srv_url,   &l);
    l = sizeof(softap_pwd_existing);  nvs_get_str(h, "softap_pwd", softap_pwd_existing, &l);
    nvs_close(h);

    if (strlen(device_id) == 0 || strlen(passkey) == 0 || strlen(srv_url) == 0) {
        ESP_LOGI(TAG, "SOFTAP SYNC: device not claimed yet, skipping");
        goto done;
    }
    if (strlen(softap_pwd_existing) >= 8) {
        ESP_LOGI(TAG, "SOFTAP SYNC: softap_pwd already set, skipping");
        goto done;
    }

    /* Wait briefly for SNTP-synced time. The signature timestamp must be
     * within ±60 s of server time, so a 1970 clock will fail. SNTP usually
     * completes within a few seconds of WiFi/cellular bring-up. */
    for (int i = 0; i < 30; i++) {
        time_t now = time(NULL);
        if (now > 1700000000) break;  /* reasonable post-2023 timestamp */
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    time_t now = time(NULL);
    if (now <= 1700000000) {
        ESP_LOGW(TAG, "SOFTAP SYNC: time not synced after 30 s, bailing");
        goto done;
    }

    /* MAC string. */
    uint8_t mac[6];
    esp_wifi_get_mac(WIFI_IF_STA, mac);
    char mac_str[18];
    snprintf(mac_str, sizeof(mac_str), "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);

    /* Signature + body. */
    char sig[65];
    compute_softap_sync_signature(passkey, device_id, mac_str, (uint32_t)now,
                                  sig, sizeof(sig));

    char body[384];
    snprintf(body, sizeof(body),
             "{\"device_id\":\"%s\",\"mac_address\":\"%s\",\"timestamp\":%lu,\"signature\":\"%s\"}",
             device_id, mac_str, (unsigned long)now, sig);

    char url[192];
    snprintf(url, sizeof(url), "%s/functions/v1/sync-softap-password", srv_url);

    /* Branch by uplink type — same pattern as provision_claim_task. */
    bool use_cellular = modem_is_present();

    for (int attempt = 1; attempt <= SOFTAP_SYNC_MAX_ATTEMPTS; attempt++) {
        char resp[256] = {0};
        size_t resp_len = 0;
        int http_status = 0;
        esp_err_t err;

        if (use_cellular) {
            char apn_buf[64] = {0};
            modem_nvs_load(apn_buf, sizeof(apn_buf), NULL, 0, NULL);
            err = modem_https_post_json(srv_url, "/functions/v1/sync-softap-password",
                                        apn_buf, body, strlen(body),
                                        resp, sizeof(resp), &resp_len, &http_status, 30000);
        } else {
            esp_http_client_config_t cfg = {
                .url               = url,
                .crt_bundle_attach = (strncmp(url, "https://", 8) == 0) ? esp_crt_bundle_attach : NULL,
                .method            = HTTP_METHOD_POST,
                .timeout_ms        = 30000,
            };
            esp_http_client_handle_t cli = esp_http_client_init(&cfg);
            if (!cli) { err = ESP_FAIL; }
            else {
                esp_http_client_set_header(cli, "Content-Type", "application/json");
                esp_http_client_set_post_field(cli, body, strlen(body));
                err = esp_http_client_open(cli, strlen(body));
                if (err == ESP_OK && esp_http_client_write(cli, body, strlen(body)) >= 0) {
                    if (esp_http_client_fetch_headers(cli) >= 0) {
                        http_status = esp_http_client_get_status_code(cli);
                        int rl = esp_http_client_read_response(cli, resp, sizeof(resp) - 1);
                        if (rl < 0) rl = 0;
                        resp[rl] = '\0';
                        resp_len = rl;
                    }
                }
                esp_http_client_close(cli);
                esp_http_client_cleanup(cli);
            }
        }

        ESP_LOGI(TAG, "SOFTAP SYNC: attempt %d HTTP %d (%zu B)", attempt, http_status, resp_len);

        if (http_status == 200) {
            cJSON *root = cJSON_Parse(resp);
            cJSON *j_pwd = root ? cJSON_GetObjectItem(root, "softap_password") : NULL;
            if (j_pwd && cJSON_IsString(j_pwd) && strlen(j_pwd->valuestring) >= 8) {
                nvs_handle_t hw;
                if (nvs_open("vmflow", NVS_READWRITE, &hw) == ESP_OK) {
                    nvs_set_str(hw, "softap_pwd", j_pwd->valuestring);
                    nvs_commit(hw);
                    nvs_close(hw);
                }
                ESP_LOGW(TAG, "SOFTAP SYNC: applied backend-assigned password — reloading AP");
                start_softap();   /* re-applies wifi_config, deauths existing clients */
                cJSON_Delete(root);
                goto done;
            }
            if (root) cJSON_Delete(root);
            ESP_LOGE(TAG, "SOFTAP SYNC: HTTP 200 but no usable softap_password — giving up");
            break;
        }
        if (http_status >= 400 && http_status < 500) {
            ESP_LOGW(TAG, "SOFTAP SYNC: server rejected %d — giving up", http_status);
            break;
        }

        if (attempt < SOFTAP_SYNC_MAX_ATTEMPTS) {
            int delay_s = SOFTAP_SYNC_RETRY_DELAYS_S[attempt - 1];
            ESP_LOGI(TAG, "SOFTAP SYNC: retrying in %d s", delay_s);
            vTaskDelay(pdMS_TO_TICKS(delay_s * 1000));
        }
    }

done:
    s_softap_sync_done    = true;
    s_softap_sync_running = false;
    vTaskDelete(NULL);
}
```

- [ ] **Step 12.3: Spawn the task from the `UPLINK_UP` handler**

Locate the existing `UPLINK_UP` event handler in `mdb-slave-esp32s3.c` (search `case NETWORK_EVENT_UPLINK_UP` — around line 2598 where `provision_claim_task` is conditionally spawned).

After the existing `xTaskCreate(provision_claim_task, ...)` block, add:

```c
                    /* Also try a SoftAP password sync for already-claimed
                     * devices that don't yet have softap_pwd in NVS. The
                     * task itself early-exits if the conditions aren't met,
                     * so this is safe to spawn unconditionally. */
                    if (!s_softap_sync_done) {
                        xTaskCreate(softap_sync_task, "softap_sync", 8192, NULL, 4, NULL);
                    }
```

The task internally checks NVS and bails fast on the no-op case. The task priority (4) is one below `provision_claim_task` (5) so they don't race for the modem if both are spawned on the same UPLINK_UP.

- [ ] **Step 12.4: Build the firmware**

```bash
cd mdb-slave-esp32s3
. $IDF_PATH/export.sh
idf.py build
```

Expected: clean build. If `mbedtls/md.h` not found, add `mbedtls` to the `REQUIRES` list in `main/CMakeLists.txt`.

- [ ] **Step 12.5: Commit**

```bash
git add mdb-slave-esp32s3/main/mdb-slave-esp32s3.c mdb-slave-esp32s3/main/CMakeLists.txt
git commit -m "feat(firmware): boot-time SoftAP password sync for already-claimed devices"
```

---

## Chunk 5: End-to-end verification

### Task 13: On-device firmware QA

**Hardware:** one ESP32-S3 development board with serial access. Wipe NVS before testing.

- [ ] **Step 13.1: Wipe NVS and flash the new firmware**

```bash
cd mdb-slave-esp32s3
. $IDF_PATH/export.sh
idf.py erase-flash
idf.py flash monitor
```

Watch the serial log on first boot. Expected:

```
SoftAP config set (SSID="VMflow-XXXXXX" auth=OPEN) → ESP_OK
```

The XXXXXX should match the last 3 bytes of the device's WiFi-STA MAC (verify with `esptool.py read_mac`). The auth mode must be `OPEN` because NVS was just wiped.

- [ ] **Step 13.2: Confirm open AP before claim**

On a phone, find `VMflow-XXXXXX` in the WiFi list — it should appear without a lock icon. Tap to join; phone should associate without prompting for a password and the captive portal should auto-pop. iOS may show "Unsecured Network" — expected.

The legacy `VMflow` SSID should NOT appear.

- [ ] **Step 13.3: Run the full claim flow**

1. In the management UI (`/devices` → "Register Device"), generate a provisioning code.
2. Through the captive portal, scan the management-UI QR (existing flow), submit. The device should:
   - log `PROV: stored backend-assigned SoftAP password`
   - log `PROV: claimed, company=... device=...`
   - reboot via `tracked_restart("provision")`.

- [ ] **Step 13.4: After reboot, verify the AP is now WPA2 with the new password**

After boot, expected serial line:

```
SoftAP config set (SSID="VMflow-XXXXXX" auth=WPA2) → ESP_OK
```

The phone's saved open-network profile will fail because the AP is now WPA2. "Forget Network", then re-join:
- Look up the password in the management UI: `/devices` → click the WiFi icon on the new row.
- Type the displayed password manually, OR scan the WiFi-QR shown in the modal.
- Phone should associate.

- [ ] **Step 13.5: Reboot, confirm password persists**

Power-cycle the device. After boot the SSID stays the same and the AP stays WPA2 with the same password (NVS preserves `softap_pwd` across reboots).

- [ ] **Step 13.6: Factory-reset, confirm fallback to open**

Hold the BOOT button for 5 seconds. After the reset reboot, the AP should be back to `auth=OPEN` — NVS was wiped, no password to use. Phone joins without password again.

- [ ] **Step 13.7: Simulate the auto-migration scenario for a legacy claimed device**

This step verifies the `softap_sync_task` path. The setup mimics a field device that was already claimed before this change shipped: NVS has `device_id` + `passkey` + `srv_url` but no `softap_pwd`.

1. Re-claim the device fresh (steps 13.3–13.4) so it has all the claim NVS fields.
2. In serial monitor, drop into the IDF console (`Ctrl-T` → `c`) or use `nvs_partition_set`/`nvs_partition_erase_key` from `idf.py monitor` Python helpers — the goal is to **erase only the `softap_pwd` key** while keeping `device_id` etc. The simplest path: stop monitor, run:
   ```
   espefuse.py erase_partition_keys is not what we want; instead use:
   esptool.py erase_region <offset> <length>
   ```
   …actually the cleanest is via firmware: temporarily add an `nvs_erase_key(h, "softap_pwd")` call somewhere reachable (e.g. on a specific MQTT cmd byte you trigger from the dev backend) just for testing, OR just use the NVS-cli partition tool to overwrite.

   **Simpler alternative for QA only:** rebuild firmware with a temporary `nvs_erase_key(h, "softap_pwd")` line at the top of `app_main` guarded by `#if SOFTAP_SYNC_QA`, flash, run once with `idf.py build -DSOFTAP_SYNC_QA=1`, observe the sync task, then remove the guard.

3. Reboot the device. Observe serial log:
   ```
   SoftAP config set (SSID="VMflow-XXXXXX" auth=OPEN) → ESP_OK   ← initial open AP
   ...UPLINK_UP fires...
   SOFTAP SYNC: applied backend-assigned password — reloading AP
   SoftAP config set (SSID="VMflow-XXXXXX" auth=WPA2) → ESP_OK   ← reloaded
   ```
4. Within ~10–20 s of boot, the AP transitions from open to WPA2 in place.
5. Phone connected to the open AP gets deauth'd; rejoins with the password from the management UI.
6. The `embeddeds.softap_password` column should be unchanged (idempotent — same value as Step 13.4).

### Task 14: Frontend manual QA

- [ ] **Step 14.1: Boot dev environment**

```bash
cd management-frontend
npm run dev
```

Open `http://localhost:3000`, log in as an admin.

- [ ] **Step 14.2: `/devices` — modal on a freshly claimed device**

Click the "WiFi" icon on the row of the device claimed during Task 13. Verify:
- Modal opens with the correct SSID (matches MAC).
- Password is masked by default; "Show" reveals it; "Copy" copies to clipboard.
- WiFi-QR renders.
- Scan the QR with a phone — phone offers to join `VMflow-XXXXXX`.

- [ ] **Step 14.3: `/devices` — modal on an open-AP device (NULL `softap_password`)**

Pick a row whose `softap_password` is NULL (devices claimed before this change). Click "WiFi":
- Amber "Open AP" banner is visible with the factory-reset hint.
- Password section is **absent** (no row, no buttons — there's no password to show).
- WiFi-QR renders using the `T:nopass` form so a phone can still join in one tap.

If no such device exists in the dev DB, simulate by manually nulling the column for one device:

```sql
UPDATE embeddeds SET softap_password = NULL WHERE id = '<some-id>';
```

- [ ] **Step 14.4: `/machines/[id]` — modal access**

Navigate to a machine detail page. Confirm the WiFi button is present and opens the same modal with correct credentials.

- [ ] **Step 14.5: Provisioning instructions are updated**

Open the "Register Device" modal on `/devices`. Step 1 of the instructions should reference picking a `VMflow-`-prefixed network and explain that fresh devices have no password (no broken HTML interpolation, no literal `VMflow / 12345678`).

- [ ] **Step 14.6: Non-admin viewer sees no WiFi button**

Log in as a viewer (or `UPDATE organization_members SET role='viewer' WHERE user_id=...` for a test user). Visit `/devices`. Confirm the WiFi icon is absent on every row.

- [ ] **Step 14.7: Locale toggle works**

Switch UI language to German. Confirm modal labels render the German translations from `de.json` (Netzwerkname, Passwort, Anzeigen, etc.).

- [ ] **Step 14.8: No console errors**

Throughout the QA, the browser dev-tools console must stay clean.

### Task 15: Final polish — release notes + close-out commit

- [ ] **Step 15.1: Add a CHANGELOG / README note**

If `mdb-slave-esp32s3/README.md` (or a CHANGELOG file) tracks user-facing changes, append:

```
- 2026-05-02: Per-device SoftAP credentials.
  - SSID is now "VMflow-XXXXXX" (last 3 bytes of MAC). Each device is
    distinguishable in WiFi pickers.
  - Unclaimed devices expose an OPEN SoftAP (no password). Joining the
    captive portal needs no typing.
  - On claim, the backend assigns a unique 12-char password and pushes it
    back to the device. From that point on the device's SoftAP is WPA2
    with that password. Admins can look it up in the management UI under
    /devices or /machines/[id] (look for the WiFi icon).
  - To rotate the password on an existing claimed device, factory-reset it
    (hold the BOOT button for 5 seconds) and re-claim.
  - Already-claimed devices auto-migrate after OTA: a one-shot HMAC-
    authenticated sync call to /functions/v1/sync-softap-password fetches
    the backend-assigned password on the first UPLINK_UP. The AP transitions
    from open to WPA2 in place within ~10–20 s of boot. No factory-reset
    needed.
```

- [ ] **Step 15.2: Verify the spec file is committed**

```bash
git log --oneline -- docs/superpowers/specs/2026-04-30-softap-per-device-credentials-design.md
git log --oneline -- docs/superpowers/plans/2026-04-30-softap-per-device-credentials.md
```

Both should show at least one commit.

- [ ] **Step 15.3: Final smoke check**

```bash
# Backend
cd Docker/supabase/functions/claim-device && deno test --allow-all

# Frontend
cd ../../../management-frontend && npx vitest run app/lib/__tests__/softap.test.ts && npm run build

# Firmware
cd ../mdb-slave-esp32s3 && idf.py build
```

All three must pass cleanly.

- [ ] **Step 15.4: Push the branch and open a PR**

```bash
git push -u origin claude/softap-per-device-credentials
gh pr create --title "feat: per-device SoftAP password assigned on claim" --body "$(cat <<'EOF'
## Summary
- New `embeddeds.softap_password` column populated by `claim-device` (server-generated, 12-char Web-Crypto random).
- Firmware reads it from NVS on boot; if absent, brings up an OPEN SoftAP (no password).
- SSID becomes per-device: `VMflow-XXXXXX` from the last 3 bytes of MAC.
- Admins can view + copy the credentials and scan a WiFi-QR from `/devices` and `/machines/[id]`.
- New Edge Function `sync-softap-password` lets already-claimed devices auto-fetch their backend-assigned password on the first UPLINK_UP after OTA, HMAC-authenticated with their existing `passkey`. No factory-reset needed for migration.

## Spec
- [`docs/superpowers/specs/2026-04-30-softap-per-device-credentials-design.md`](docs/superpowers/specs/2026-04-30-softap-per-device-credentials-design.md)

## Test plan
- [ ] Migration applies cleanly (`supabase migration up`).
- [ ] `claim-device` Deno tests pass (`deno test --allow-all`).
- [ ] Frontend `softap.test.ts` passes (`npx vitest run`).
- [ ] Firmware builds (`idf.py build`).
- [ ] On-device QA per the plan's Task 13 (factory-reset → SSID + open AP → claim → reboot → WPA2 with unique password works → factory-reset → back to open AP; plus auto-migration: legacy NVS state → sync task fires → AP transitions to WPA2).
- [ ] Frontend manual QA per the plan's Task 14 (admin sees modal, viewer doesn't, German renders).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Confirm the PR URL printed. Done.
