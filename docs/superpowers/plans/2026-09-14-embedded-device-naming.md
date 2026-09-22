# Embedded Device Naming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin assign a free-text name/label to an `embeddeds` row (a registered ESP32 device), settable at registration time or afterwards, shown everywhere a device is listed so multiple physical devices and hardware revisions can be told apart.

**Architecture:** One additive DB migration adds a nullable `name` column to `embeddeds`. The existing `create-provisioning-token` edge function already threads an optional `name` through to `device_provisioning`; `claim-device` is extended to copy that name onto the new `embeddeds` row it creates. The `/devices` admin page gains a name input in its registration modal and inline-editable name display/edit on the device list (a direct PostgREST `UPDATE`, no new edge function, since the existing `embeddeds_update` RLS policy already allows company admins to update arbitrary columns on their own rows). The machine-detail device swap dropdown is updated to show the name when set.

**Tech Stack:** PostgreSQL/Supabase migrations, Deno edge functions (`Docker/supabase/functions/`), Nuxt 4 / Vue 3 / TypeScript (`management-frontend/`), `@nuxtjs/i18n`.

## Global Constraints

- Migrations under `Docker/supabase/migrations/` are immutable once committed — this plan only ever adds a new migration file, never edits an existing one.
- All DB changes must be additive/backward-compatible: the new column is nullable with no default requirement, so existing rows and old firmware are unaffected.
- No firmware or MQTT protocol changes — the device name is a pure management-plane label.
- Frontend must keep all four locales (`en`, `de`, `fr`, `nl`) in sync for any new user-facing string — see `management-frontend/i18n/locales/*.json`.
- Do not run `supabase db reset`. Use `supabase migration up` to apply the new migration to the local dev DB.

---

### Task 1: Database migration — add `embeddeds.name`

**Files:**
- Create: `Docker/supabase/migrations/20260914000000_embeddeds_name.sql`

**Interfaces:**
- Produces: `embeddeds.name` (nullable `text` column) — consumed by Task 3 (`claim-device`), Task 6 (`/devices` page), Task 7 (swap dropdown via `useMachines.ts`).

- [ ] **Step 1: Write the migration file**

```sql
-- Free-text label for an embedded device, independent of whichever
-- vendingMachine it's currently installed in (a device can be swapped
-- between machines, e.g. for hardware-revision replacements). NULL means
-- unnamed — UI falls back to mac_address/subdomain in that case.

ALTER TABLE embeddeds
  ADD COLUMN IF NOT EXISTS name text;

COMMENT ON COLUMN embeddeds.name IS
  'Optional admin-assigned label to tell multiple physical devices/hardware revisions apart. NULL = unnamed, UI falls back to mac_address/subdomain.';
```

- [ ] **Step 2: Apply the migration to the local dev stack**

Run:
```bash
cd Docker/supabase && supabase migration up
```
Expected: output lists `20260914000000_embeddeds_name.sql` as applied, no errors.

- [ ] **Step 3: Verify the column exists**

Run:
```bash
cd Docker/supabase && supabase db execute --sql "select column_name, is_nullable, data_type from information_schema.columns where table_name = 'embeddeds' and column_name = 'name';"
```
Expected: one row — `name | YES | text`. (If your local Supabase CLI version doesn't support `db execute`, instead open Studio at `http://127.0.0.1:54323`, go to the `embeddeds` table, and confirm the `name` column is present and nullable.)

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/migrations/20260914000000_embeddeds_name.sql
git commit -m "$(cat <<'EOF'
feat(db): add nullable name column to embeddeds

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: i18n strings for device naming UI

**Files:**
- Modify: `management-frontend/i18n/locales/en.json`
- Modify: `management-frontend/i18n/locales/de.json`
- Modify: `management-frontend/i18n/locales/fr.json`
- Modify: `management-frontend/i18n/locales/nl.json`

**Interfaces:**
- Produces: i18n keys `devices.nameCol`, `devices.addName`, `devices.deviceName`, `devices.deviceNamePlaceholder` — consumed by Task 5 (registration modal) and Task 6 (`/devices` list/inline edit).

- [ ] **Step 1: Add the four new keys to `en.json`**

In `management-frontend/i18n/locales/en.json`, inside the `"devices"` object, add these four keys (anywhere in the object; e.g. right after `"macAddressCol": "MAC Address",`):

```json
  "nameCol": "Name",
  "addName": "Add name",
  "deviceName": "Device Name (optional)",
  "deviceNamePlaceholder": "e.g. Rev B – blue crate",
```

- [ ] **Step 2: Add the same keys to `de.json`**

Inside the `"devices"` object in `management-frontend/i18n/locales/de.json`:

```json
  "nameCol": "Name",
  "addName": "Namen hinzufügen",
  "deviceName": "Gerätename (optional)",
  "deviceNamePlaceholder": "z. B. Rev B – blaue Kiste",
```

- [ ] **Step 3: Add the same keys to `fr.json`**

Inside the `"devices"` object in `management-frontend/i18n/locales/fr.json`:

```json
  "nameCol": "Nom",
  "addName": "Ajouter un nom",
  "deviceName": "Nom de l'appareil (facultatif)",
  "deviceNamePlaceholder": "ex. Rev B – caisse bleue",
```

- [ ] **Step 4: Add the same keys to `nl.json`**

Inside the `"devices"` object in `management-frontend/i18n/locales/nl.json`:

```json
  "nameCol": "Naam",
  "addName": "Naam toevoegen",
  "deviceName": "Toestelnaam (optioneel)",
  "deviceNamePlaceholder": "bijv. Rev B – blauwe krat",
```

- [ ] **Step 5: Verify all four files are still valid JSON**

Run:
```bash
cd management-frontend && for f in i18n/locales/en.json i18n/locales/de.json i18n/locales/fr.json i18n/locales/nl.json; do python3 -m json.tool "$f" > /dev/null && echo "$f OK"; done
```
Expected: `OK` printed for all four files, no `json.decoder.JSONDecodeError`.

- [ ] **Step 6: Commit**

```bash
git add management-frontend/i18n/locales/en.json management-frontend/i18n/locales/de.json management-frontend/i18n/locales/fr.json management-frontend/i18n/locales/nl.json
git commit -m "$(cat <<'EOF'
i18n: add device-naming strings for all locales

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `claim-device` writes the provisioning name onto the new `embeddeds` row

**Files:**
- Modify: `Docker/supabase/functions/claim-device/index.ts:128-142`

**Interfaces:**
- Consumes: `token.name` (already selected at `index.ts:64`, `string | null`), `embeddeds.name` column from Task 1.
- Produces: every newly claimed `embeddeds` row now has its `name` set from the provisioning token that created it (previously this value was discarded when `device_only` was true, which is the only path the frontend uses today).

- [ ] **Step 1: Add `name` to the `embeddeds` insert**

In `Docker/supabase/functions/claim-device/index.ts`, find the insert block (currently lines 129-140):

```ts
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
```

Replace it with:

```ts
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
        name: token.name ?? null,
      })
      .select('id, subdomain')
      .single()
```

(The existing `vendingMachine` auto-naming a few lines below, which also reads `token.name`, is untouched — a device can now carry its own name independently of whatever machine name gets auto-generated for the non-`device_only` path.)

- [ ] **Step 2: Run the existing Deno unit tests to confirm no regression**

Run:
```bash
cd Docker/supabase/functions/claim-device && deno test
```
Expected: all 4 existing `generateSoftApPassword` tests still `PASS` (this file doesn't test the HTTP handler itself, only the exported helper, which is untouched).

- [ ] **Step 3: Manually verify against the local dev stack**

With `supabase start` running (`cd Docker/supabase && supabase start` if not already up), create a named provisioning token and claim it end-to-end via curl. First get an admin JWT by logging into the local frontend and copying it from browser dev tools (`Application → Local Storage`, the `sb-...-auth-token` entry's `access_token`), then:

```bash
curl -s -X POST http://127.0.0.1:54321/functions/v1/create-provisioning-token \
  -H "Authorization: Bearer <admin_access_token>" \
  -H "Content-Type: application/json" \
  -d '{"name": "Test Rev B", "device_only": true}'
```
Expected: `{"short_code":"...", "expires_at":"..."}`. Then:

```bash
curl -s -X POST http://127.0.0.1:54321/functions/v1/claim-device \
  -H "Content-Type: application/json" \
  -d '{"short_code": "<short_code_from_above>", "mac_address": "AA:BB:CC:DD:EE:FF"}'
```
Expected: `{"company_id":"...", "device_id":"...", "passkey":"...", ...}`. Then confirm the name landed on the device:

```bash
cd Docker/supabase && supabase db execute --sql "select mac_address, name from embeddeds where mac_address = 'AA:BB:CC:DD:EE:FF';"
```
Expected: one row with `name = 'Test Rev B'`. Clean up the test row afterwards:

```bash
supabase db execute --sql "delete from embeddeds where mac_address = 'AA:BB:CC:DD:EE:FF';"
```

- [ ] **Step 4: Commit**

```bash
git add Docker/supabase/functions/claim-device/index.ts
git commit -m "$(cat <<'EOF'
feat(claim-device): write provisioning name onto the embeddeds row

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `useMachines.ts` — expose `name` on unassigned devices

**Files:**
- Modify: `management-frontend/app/composables/useMachines.ts:4-16` (interface)
- Modify: `management-frontend/app/composables/useMachines.ts:425-443` (`fetchUnassignedEmbeddeds`)

**Interfaces:**
- Consumes: `embeddeds.name` column from Task 1.
- Produces: `Embedded.name: string | null` field; `fetchUnassignedEmbeddeds(): Promise<Embedded[]>` now returns rows including `name` — consumed by Task 7 (swap dropdown).

- [ ] **Step 1: Add `name` to the `Embedded` interface**

In `management-frontend/app/composables/useMachines.ts`, the interface currently reads (lines 4-16):

```ts
interface Embedded {
  id: string
  status: string
  status_at: string
  subdomain: number
  mac_address?: string
  firmware_version?: string
  firmware_build_date?: string
  mdb_diagnostics?: Record<string, unknown> | null
  last_restart_reason?: string | null
  last_restart_at?: string | null
  online_since?: string | null
}
```

Add a `name` field:

```ts
interface Embedded {
  id: string
  status: string
  status_at: string
  subdomain: number
  mac_address?: string
  firmware_version?: string
  firmware_build_date?: string
  mdb_diagnostics?: Record<string, unknown> | null
  last_restart_reason?: string | null
  last_restart_at?: string | null
  online_since?: string | null
  name?: string | null
}
```

- [ ] **Step 2: Add `name` to the `fetchUnassignedEmbeddeds` select**

The function currently reads (lines 425-443):

```ts
  async function fetchUnassignedEmbeddeds() {
    const supabase = useSupabaseClient()

    const [allRes, assignedRes] = await Promise.all([
      supabase
        .from('embeddeds')
        .select('id, mac_address, subdomain, status, status_at, firmware_version, firmware_build_date'),
      supabase
        .from('vendingMachine')
        .select('embedded')
        .not('embedded', 'is', null),
    ])

    const assignedIds = new Set(
      (assignedRes.data ?? []).map((m: any) => m.embedded).filter(Boolean)
    )

    return ((allRes.data ?? []) as Embedded[]).filter(e => !assignedIds.has(e.id))
  }
```

Update the `select` string to include `name`:

```ts
  async function fetchUnassignedEmbeddeds() {
    const supabase = useSupabaseClient()

    const [allRes, assignedRes] = await Promise.all([
      supabase
        .from('embeddeds')
        .select('id, mac_address, subdomain, status, status_at, firmware_version, firmware_build_date, name'),
      supabase
        .from('vendingMachine')
        .select('embedded')
        .not('embedded', 'is', null),
    ])

    const assignedIds = new Set(
      (assignedRes.data ?? []).map((m: any) => m.embedded).filter(Boolean)
    )

    return ((allRes.data ?? []) as Embedded[]).filter(e => !assignedIds.has(e.id))
  }
```

- [ ] **Step 3: Typecheck**

Run:
```bash
cd management-frontend && npx nuxt typecheck
```
Expected: no new errors referencing `useMachines.ts` or `Embedded`.

- [ ] **Step 4: Commit**

```bash
git add management-frontend/app/composables/useMachines.ts
git commit -m "$(cat <<'EOF'
feat(frontend): expose embedded device name from fetchUnassignedEmbeddeds

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Registration modal — optional name input

**Files:**
- Modify: `management-frontend/app/pages/devices/index.vue`

**Interfaces:**
- Consumes: i18n keys `devices.deviceName`, `devices.deviceNamePlaceholder` from Task 2; `create-provisioning-token`'s existing optional `{ name }` body param (no edge function change needed — already implemented).
- Produces: newly registered devices can carry a name from the moment they're claimed (via Task 3).

- [ ] **Step 1: Add a `deviceName` ref next to the other modal state**

In `management-frontend/app/pages/devices/index.vue`, the modal state block currently reads (lines 132-140):

```ts
// ── Register Device modal ──────────────────────────────────────────────────
const showModal = ref(false)
const step = ref<1 | 2>(1)
const generating = ref(false)
const shortCode = ref('')
const expiresAt = ref('')
const genError = ref('')
const qrDataUrl = ref('')
const qrSrvUrl = ref('')
```

Add `deviceName`:

```ts
// ── Register Device modal ──────────────────────────────────────────────────
const showModal = ref(false)
const step = ref<1 | 2>(1)
const generating = ref(false)
const shortCode = ref('')
const expiresAt = ref('')
const genError = ref('')
const qrDataUrl = ref('')
const qrSrvUrl = ref('')
const deviceName = ref('')
```

- [ ] **Step 2: Reset `deviceName` in `openModal`**

Currently (lines 142-148):

```ts
function openModal() {
  step.value = 1
  shortCode.value = ''
  expiresAt.value = ''
  genError.value = ''
  showModal.value = true
}
```

Update to:

```ts
function openModal() {
  step.value = 1
  shortCode.value = ''
  expiresAt.value = ''
  genError.value = ''
  deviceName.value = ''
  showModal.value = true
}
```

- [ ] **Step 3: Pass the name through in `generateCode`**

Currently (lines 150-170), the invoke call is:

```ts
    const { data, error } = await supabase.functions.invoke('create-provisioning-token', {
      body: { device_only: true },
    })
```

Update to:

```ts
    const { data, error } = await supabase.functions.invoke('create-provisioning-token', {
      body: { device_only: true, name: deviceName.value.trim() || undefined },
    })
```

- [ ] **Step 4: Add the input field to step 1 of the modal template**

Currently (lines 552-574):

```html
      <!-- Step 1: Generate code -->
      <template v-if="step === 1">
        <h2 class="mb-1 text-lg font-semibold">{{ t('devices.registerADevice') }}</h2>
        <p class="mb-5 text-sm text-muted-foreground">
          {{ t('devices.registerDescription') }}
        </p>
        <FormError :message="genError" class="mb-3" />
        <div class="flex gap-2">
          <button
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium hover:bg-muted"
            @click="closeModal"
          >
            {{ t('common.cancel') }}
          </button>
          <button
            :disabled="generating"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
            @click="generateCode"
          >
            <span v-if="generating">{{ t('devices.generating') }}</span>
            <span v-else>{{ t('devices.generateCode') }}</span>
          </button>
        </div>
      </template>
```

Insert a labeled text input between the description and the `FormError`:

```html
      <!-- Step 1: Generate code -->
      <template v-if="step === 1">
        <h2 class="mb-1 text-lg font-semibold">{{ t('devices.registerADevice') }}</h2>
        <p class="mb-5 text-sm text-muted-foreground">
          {{ t('devices.registerDescription') }}
        </p>
        <div class="mb-4 space-y-1">
          <label class="text-sm font-medium" for="device-name-input">{{ t('devices.deviceName') }}</label>
          <input
            id="device-name-input"
            v-model="deviceName"
            type="text"
            maxlength="60"
            :placeholder="t('devices.deviceNamePlaceholder')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <FormError :message="genError" class="mb-3" />
        <div class="flex gap-2">
          <button
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium hover:bg-muted"
            @click="closeModal"
          >
            {{ t('common.cancel') }}
          </button>
          <button
            :disabled="generating"
            class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
            @click="generateCode"
          >
            <span v-if="generating">{{ t('devices.generating') }}</span>
            <span v-else>{{ t('devices.generateCode') }}</span>
          </button>
        </div>
      </template>
```

- [ ] **Step 5: Manually verify in the dev server**

Run:
```bash
cd management-frontend && npm run dev
```
Open `http://localhost:3000/devices`, click "Register Device", type a name (e.g. "Test Rev B"), click "Generate Code". Expected: the modal advances to step 2 showing a code/QR as before (the name field doesn't block or alter that flow). Stop the dev server when done (`Ctrl+C`) — leave verification of the name actually landing on the device to Task 6, once the list can display it.

- [ ] **Step 6: Commit**

```bash
git add management-frontend/app/pages/devices/index.vue
git commit -m "$(cat <<'EOF'
feat(devices): add optional name field to device registration

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `/devices` list — display and inline-edit the device name

**Files:**
- Modify: `management-frontend/app/pages/devices/index.vue`

**Interfaces:**
- Consumes: `embeddeds.name` column from Task 1; i18n keys `devices.nameCol`, `devices.addName` from Task 2; existing `embeddeds_update` RLS policy (admin, own company — already in place, no migration needed).
- Produces: device name visible and editable on both the mobile card and desktop table layouts; searchable via the existing fuzzy filter.

- [ ] **Step 1: Add `name` to the `EmbeddedDevice` interface**

Currently (lines 44-57):

```ts
interface EmbeddedDevice {
  id: string
  created_at: string
  subdomain: number
  mac_address: string | null
  status: string
  status_at: string
  firmware_version: string | null
  firmware_build_date: string | null
  mdb_diagnostics: Record<string, unknown> | null
  softap_password: string | null
  machine_name: string | null
  machine_id: string | null
}
```

Add `name`:

```ts
interface EmbeddedDevice {
  id: string
  created_at: string
  subdomain: number
  mac_address: string | null
  status: string
  status_at: string
  firmware_version: string | null
  firmware_build_date: string | null
  mdb_diagnostics: Record<string, unknown> | null
  softap_password: string | null
  machine_name: string | null
  machine_id: string | null
  name: string | null
}
```

- [ ] **Step 2: Add `name` to the `fetchDevices` select**

Currently (line 68):

```ts
      .select('id, created_at, subdomain, mac_address, status, status_at, firmware_version, firmware_build_date, mdb_diagnostics, softap_password')
```

Update to:

```ts
      .select('id, created_at, subdomain, mac_address, status, status_at, firmware_version, firmware_build_date, mdb_diagnostics, softap_password, name')
```

- [ ] **Step 3: Include `name` in the fuzzy search filter**

Currently (lines 21-28):

```ts
const sortedDevices = computed(() => {
  const filtered = fuzzyFilter(devices.value, deviceSearch.value, [
    d => d.mac_address,
    d => d.machine_name,
    d => d.status,
    d => d.firmware_version,
    d => String(d.subdomain),
  ])
```

Add `d => d.name`:

```ts
const sortedDevices = computed(() => {
  const filtered = fuzzyFilter(devices.value, deviceSearch.value, [
    d => d.mac_address,
    d => d.machine_name,
    d => d.status,
    d => d.firmware_version,
    d => String(d.subdomain),
    d => d.name,
  ])
```

- [ ] **Step 4: Merge `name` on realtime updates**

Currently, `subscribeToDeviceUpdates` (lines 106-130) merges individual fields with `??`, which is wrong for a field that can legitimately be cleared to `null` (an admin removing another admin's name edit in real time). Find the merge block:

```ts
        const idx = devices.value.findIndex(d => d.id === updated.id)
        if (idx !== -1) {
          const existing = devices.value[idx]!
          existing.status = updated.status ?? existing.status
          existing.status_at = updated.status_at ?? existing.status_at
          existing.firmware_version = updated.firmware_version ?? existing.firmware_version
          existing.firmware_build_date = updated.firmware_build_date ?? existing.firmware_build_date
          existing.mdb_diagnostics = updated.mdb_diagnostics ?? existing.mdb_diagnostics
        }
```

Add a direct (non-`??`) assignment for `name`, since `updated` is always the full new row from Postgres and `null` is a meaningful value here:

```ts
        const idx = devices.value.findIndex(d => d.id === updated.id)
        if (idx !== -1) {
          const existing = devices.value[idx]!
          existing.status = updated.status ?? existing.status
          existing.status_at = updated.status_at ?? existing.status_at
          existing.firmware_version = updated.firmware_version ?? existing.firmware_version
          existing.firmware_build_date = updated.firmware_build_date ?? existing.firmware_build_date
          existing.mdb_diagnostics = updated.mdb_diagnostics ?? existing.mdb_diagnostics
          existing.name = updated.name
        }
```

- [ ] **Step 5: Add inline-edit state and functions**

Add this block right after the "── Delete device ──" section (after the `confirmDelete` function, currently ending at line 233, before the "── SoftAP credentials modal ──" comment at line 235):

```ts
// ── Inline name edit ────────────────────────────────────────────────────
const editingNameId = ref<string | null>(null)
const editingNameValue = ref('')

function startEditName(device: EmbeddedDevice) {
  editingNameId.value = device.id
  editingNameValue.value = device.name ?? ''
}

function cancelEditName() {
  editingNameId.value = null
}

async function saveName(device: EmbeddedDevice) {
  const newName = editingNameValue.value.trim() || null
  editingNameId.value = null
  if (newName === device.name) return
  const { error } = await supabase
    .from('embeddeds')
    .update({ name: newName })
    .eq('id', device.id)
  if (!error) device.name = newName
}
```

- [ ] **Step 6: Add the name row to the mobile card layout**

Currently, the mobile card's top row (lines 317-361) starts with subdomain + status. Insert a name row above it — find the card's opening div:

```html
          <div
            v-for="device in sortedDevices"
            :key="device.id"
            class="rounded-lg border bg-card p-4 transition-colors"
          >
            <!-- Top row: Subdomain + Status + Delete -->
            <div class="flex items-center justify-between mb-3">
```

Insert a name row right after the opening `<div class="rounded-lg ...">` and before the "Top row" comment:

```html
          <div
            v-for="device in sortedDevices"
            :key="device.id"
            class="rounded-lg border bg-card p-4 transition-colors"
          >
            <!-- Name row -->
            <div class="mb-2">
              <input
                v-if="editingNameId === device.id"
                v-model="editingNameValue"
                type="text"
                maxlength="60"
                autofocus
                class="h-7 w-full rounded border bg-background px-2 text-sm font-medium"
                @keyup.enter="saveName(device)"
                @keyup.esc="cancelEditName"
                @blur="saveName(device)"
              />
              <button
                v-else
                type="button"
                class="text-left text-sm hover:underline"
                :class="device.name ? 'font-medium' : 'text-muted-foreground italic'"
                @click="startEditName(device)"
              >
                {{ device.name ?? t('devices.addName') }}
              </button>
            </div>
            <!-- Top row: Subdomain + Status + Delete -->
            <div class="flex items-center justify-between mb-3">
```

- [ ] **Step 7: Add a "Name" column to the desktop table**

Currently, the table header (lines 404-422) starts with the Subdomain column:

```html
              <tr class="border-b bg-muted/50 text-left">
                <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleDevSort('subdomain')">
                  <SortHeader :icon="devSortIcon('subdomain')">{{ t('devices.subdomainCol') }}</SortHeader>
                </th>
```

Add a "Name" header before it:

```html
              <tr class="border-b bg-muted/50 text-left">
                <th class="px-4 py-3 font-medium">{{ t('devices.nameCol') }}</th>
                <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleDevSort('subdomain')">
                  <SortHeader :icon="devSortIcon('subdomain')">{{ t('devices.subdomainCol') }}</SortHeader>
                </th>
```

And the corresponding body cell — currently the row starts with (lines 425-430):

```html
              <tr
                v-for="device in sortedDevices"
                :key="device.id"
                class="border-b last:border-0 hover:bg-muted/30 transition-colors"
              >
                <td class="px-4 py-3 font-mono">{{ device.subdomain }}</td>
```

Add a name cell before the subdomain cell:

```html
              <tr
                v-for="device in sortedDevices"
                :key="device.id"
                class="border-b last:border-0 hover:bg-muted/30 transition-colors"
              >
                <td class="px-4 py-3">
                  <input
                    v-if="editingNameId === device.id"
                    v-model="editingNameValue"
                    type="text"
                    maxlength="60"
                    autofocus
                    class="h-7 w-full max-w-[10rem] rounded border bg-background px-2 text-sm"
                    @keyup.enter="saveName(device)"
                    @keyup.esc="cancelEditName"
                    @blur="saveName(device)"
                  />
                  <button
                    v-else
                    type="button"
                    class="text-left hover:underline"
                    :class="device.name ? 'font-medium' : 'text-muted-foreground italic'"
                    @click="startEditName(device)"
                  >
                    {{ device.name ?? t('devices.addName') }}
                  </button>
                </td>
                <td class="px-4 py-3 font-mono">{{ device.subdomain }}</td>
```

- [ ] **Step 8: Typecheck**

Run:
```bash
cd management-frontend && npx nuxt typecheck
```
Expected: no new errors referencing `devices/index.vue`.

- [ ] **Step 9: Manually verify in the dev server**

Run:
```bash
cd management-frontend && npm run dev
```
Open `http://localhost:3000/devices`:
1. Confirm the device you registered with a name in Task 5 (or any existing device) shows an "Add name" placeholder (if unnamed) or its name, in both the table (desktop width) and card (narrow window / mobile emulation) layouts.
2. Click the name/placeholder, type a new name, press Enter. Expected: it saves and the input collapses back to the button showing the new name.
3. Refresh the page. Expected: the name persists (confirms the DB write worked).
4. Type the name into the search box at the top. Expected: the device list filters down to matching devices.
5. Clear a name back to empty and save. Expected: it reverts to showing the "Add name" placeholder.

Stop the dev server (`Ctrl+C`) when done.

- [ ] **Step 10: Commit**

```bash
git add management-frontend/app/pages/devices/index.vue
git commit -m "$(cat <<'EOF'
feat(devices): display and inline-edit device names on the list

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Swap/reassign dropdown shows the device name

**Files:**
- Modify: `management-frontend/app/pages/machines/[id]/index.vue:2586-2588`

**Interfaces:**
- Consumes: `Embedded.name` from Task 4's updated `fetchUnassignedEmbeddeds()`.

- [ ] **Step 1: Update the option label**

Currently (lines 2586-2588):

```html
                <option v-for="d in availableDevices" :key="d.id" :value="d.id">
                  {{ d.mac_address ?? 'Unknown MAC' }} — subdomain {{ d.subdomain }} ({{ d.status }}{{ d.firmware_version ? `, v${d.firmware_version}` : '' }})
                </option>
```

Update to lead with the name when present:

```html
                <option v-for="d in availableDevices" :key="d.id" :value="d.id">
                  {{ d.name ? d.name + ' — ' : '' }}{{ d.mac_address ?? 'Unknown MAC' }} — subdomain {{ d.subdomain }} ({{ d.status }}{{ d.firmware_version ? `, v${d.firmware_version}` : '' }})
                </option>
```

- [ ] **Step 2: Manually verify in the dev server**

Run:
```bash
cd management-frontend && npm run dev
```
Open a machine's detail page for a machine with no device assigned (or unassign one via `/devices` first), click to assign/change device. Expected: the dropdown lists unassigned devices, and any device with a name set (from Task 5/6) shows `"<name> — <mac> — subdomain <n> (...)"`, while unnamed devices show the unchanged `"<mac> — subdomain <n> (...)"` format. Stop the dev server (`Ctrl+C`) when done.

- [ ] **Step 3: Commit**

```bash
git add "management-frontend/app/pages/machines/[id]/index.vue"
git commit -m "$(cat <<'EOF'
feat(machines): show device name in the swap/reassign dropdown

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Post-implementation

Update `CLAUDE.md`'s `embeddeds` table column list (in the "Database Schema" section) to include the new `name` column, since that list is documented as the authoritative catalog of DB columns for future sessions.
