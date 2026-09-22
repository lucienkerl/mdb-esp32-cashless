# Embedded Device Naming — Design

**Date**: 2026-09-14
**Status**: Approved

## Problem

`embeddeds` rows (registered ESP32 devices) have no user-facing name. Everywhere
a device is listed — the `/devices` admin table and the device swap/reassign
dropdown on a machine's detail page — it is identified only by `mac_address`
and `subdomain` (an auto-incrementing integer). This makes it hard for an
operator with several physical devices (or several hardware revisions of the
same board) to tell them apart, especially in the swap dropdown where the only
context is a raw MAC address.

Note: `vendingMachine.name` already exists, but it names the *machine*, not
the *device*. A device is a separate, potentially swappable piece of hardware
(1:1, optional FK from `vendingMachine.embedded`), and needs its own identity
independent of whichever machine it's currently installed in.

## Goals

- Let an admin assign a free-text name/label to an `embeddeds` row.
- Show that name (with graceful fallback to mac/subdomain) everywhere a device
  is listed: `/devices` table and the machine-detail swap dropdown.
- Allow setting the name either at registration time or afterwards.

## Non-goals

- No structured "hardware revision" field — a single free-text field is
  sufficient (the user can encode revision info in the name itself, e.g.
  "ESP32 Rev B – blau").
- No iOS/Android UI changes — neither client has a standalone device registry
  screen comparable to `/devices`; device info there is only ever shown nested
  inside a machine's own health/diagnostics tabs, where this ambiguity doesn't
  arise.
- No firmware or MQTT changes — the name is a pure management-plane label, not
  synced to the device itself.
- No uniqueness constraint on the name.

## Design

### 1. Data model

New migration adds a nullable `name text` column to `embeddeds`:

```sql
ALTER TABLE public.embeddeds ADD COLUMN IF NOT EXISTS name text;
```

No RLS changes needed — the existing `embeddeds_update` policy
(`Docker/supabase/migrations/20260228000000_multitenancy.sql:204-206`) already
lets a company admin update arbitrary columns on their own `embeddeds` rows
directly via PostgREST:

```sql
create policy "embeddeds_update" on public.embeddeds
  for update to authenticated
  using (company = public.my_company_id() and public.i_am_admin());
```

No DB-level length constraint; the frontend caps input at 60 characters.

### 2. Registration flow

`create-provisioning-token` already accepts an optional `{ name }` and stores
it on `device_provisioning.name` — no edge function change needed there.

The `/devices` registration modal (step 1, before code generation) gets an
optional "Name" text input. Its value is passed through the existing
`create-provisioning-token` call:

```js
supabase.functions.invoke('create-provisioning-token', {
  body: { name: deviceName || undefined, device_only: true }
})
```

`claim-device/index.ts` currently only ever consumes `token.name` to build the
auto-created `vendingMachine`'s name, and only when `!token.device_only` (a
path the `/devices` UI never takes today). It's extended to also write the
name onto the new `embeddeds` row itself, unconditionally:

```js
.from('embeddeds')
.insert({
  ...
  name: token.name ?? null,
})
```

The existing `vendingMachine` auto-naming behavior for the non-`device_only`
path is unchanged.

### 3. `/devices` page

- `fetchDevices()`'s select gets `name` added to its column list.
- The device name (if set) is shown as the primary label in the table/cards,
  with `mac_address`/`subdomain` retained as secondary detail, same as today's
  layout otherwise.
- The name becomes inline-editable (click to edit, save on blur/enter) via a
  direct `supabase.from('embeddeds').update({ name })` call, matching the
  existing pattern of direct-from-page mutations already used for delete
  (`confirmDelete`). No new modal.

### 4. Swap/reassign dropdown (machine detail page)

- `useMachines.ts`'s `fetchUnassignedEmbeddeds()` select gets `name` added.
- The `<option>` label in `management-frontend/app/pages/machines/[id]/index.vue`
  is extended to lead with the name when present:

  ```
  {{ d.name ? d.name + ' — ' : '' }}{{ d.mac_address ?? 'Unknown MAC' }} — subdomain {{ d.subdomain }} ({{ d.status }}{{ d.firmware_version ? `, v${d.firmware_version}` : '' }})
  ```

  When `name` is null, the label is unchanged from today.

## Testing

No existing Vitest coverage for `devices.vue` or the swap dropdown template.
Given the change is a straightforward display/edit of one text field with no
business logic, this will be verified manually in the dev server (register a
device with a name, edit a name on an existing device, confirm it appears
correctly in both the `/devices` table and the swap dropdown) rather than by
adding new test infrastructure.

## Migration compatibility

Per the immutable-migrations rule, this ships as a new, additive migration
file (`ALTER TABLE ... ADD COLUMN IF NOT EXISTS`) — safe to re-run and a no-op
on installs that already have it. Old firmware is completely unaffected since
nothing here touches the device-facing protocol.
