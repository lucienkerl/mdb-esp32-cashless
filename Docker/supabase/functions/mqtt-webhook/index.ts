import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { decodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts'
import { sendPushToUsers } from '../_shared/web-push.ts'
import { stockUrgency } from './stock-urgency.ts'
import { t, formatPrice, type Locale } from '../_shared/notification-i18n.ts'
import { decideSuppress, rebootCorroborates, REBOOT_CORRELATION_WINDOW_MS, REBOOT_CORRELATION_FORWARD_MS, SUPPRESS_WINDOW_MS, type SuppressCandidate } from "./suppress.ts";

// Sale payload format version carried in byte 1 of the 19-byte XOR-encrypted
// payload. v2 adds per-device monotonic sale_seq (bytes 14-17) + time_uncertain
// flag (byte 12 bit 0) so replays from the firmware queue or broker retention
// can be de-duplicated at the DB layer.
const SALE_PAYLOAD_V2 = 0x02;

function fromScaleFactor(p: number, x: number, y: number): number {
  return p * x * Math.pow(10, -y);
}

// --- DEX / EVA-DTS audit parser -------------------------------------------
// Extracts per-slot cumulative vend counters from a DEX audit stream. We only
// look at PA1 records: `PA1*<item_number>*<price>*<historical_vends>*<historical_value>*...`
// where fields are delimited by `*` and records by newline/CR. This is enough
// for sales reconciliation; deeper parsing (PA2, EA*, MA*) can be added later.
interface DexParseResult {
  slot_counters: Record<string, { vends: number; value_cents: number }>;
  total_vends: number;
  total_value: number;
}

function parseDexAudit(bytes: Uint8Array): DexParseResult {
  const text = new TextDecoder('latin1').decode(bytes);
  const slot_counters: Record<string, { vends: number; value_cents: number }> = {};
  let total_vends = 0;
  let total_value_cents = 0;

  // DEX records are separated by CR/LF; split tolerantly.
  for (const rawLine of text.split(/[\r\n]+/)) {
    const line = rawLine.trim();
    if (!line.startsWith('PA1')) continue;

    const fields = line.split('*');
    if (fields.length < 5) continue;

    const itemNumber = fields[1]?.trim();
    const vends = Number.parseInt(fields[3] ?? '', 10);
    const valueCents = Number.parseInt(fields[4] ?? '', 10);

    if (!itemNumber || !Number.isFinite(vends) || !Number.isFinite(valueCents)) continue;

    slot_counters[itemNumber] = { vends, value_cents: valueCents };
    total_vends += vends;
    total_value_cents += valueCents;
  }

  return {
    slot_counters,
    total_vends,
    total_value: total_value_cents / 100,
  };
}

Deno.serve(async (req) => {
  try {
    // Verify webhook secret
    const secret = req.headers.get('X-Webhook-Secret');
    const expectedSecret = Deno.env.get('MQTT_WEBHOOK_SECRET');
    if (!expectedSecret || secret !== expectedSecret) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), { status: 401 });
    }

    const body = await req.json();
    const { topic, payload: payloadB64 } = body;

    // Parse topic: /{company_id}/{device_id}/{event_type}
    const match = topic.match(/^\/([^/]+)\/([^/]+)\/(sale|status|paxcounter|mdb-log|restart|dex)$/);
    if (!match) {
      return new Response(JSON.stringify({ error: 'invalid topic' }), { status: 400 });
    }

    const companyId = match[1];
    const deviceId = match[2];
    const eventType = match[3];

    // Service-role admin client (machine-to-machine, no user auth)
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    );

    // Status event: simple UTF-8 payload, no encryption
    // Formats: "online|v:1.0.0|b:Mar  1 2026 14:30:00 +0100", "offline", "ota_updating", "ota_success", "ota_failed"
    if (eventType === 'status') {
      const statusBytes = decodeBase64(payloadB64);
      const rawStatus = new TextDecoder().decode(statusBytes);

      // Parse "online|v:1.0.0|b:Mar  1 2026 14:30:00 +0100"
      // → status = "online", firmware_version = "1.0.0", build_date = ISO timestamp
      const parts = rawStatus.split('|');
      const status = parts[0];
      let firmwareVersion: string | undefined;
      let firmwareBuildDate: string | undefined;

      for (let i = 1; i < parts.length; i++) {
        if (parts[i].startsWith('v:')) {
          firmwareVersion = parts[i].substring(2);
        } else if (parts[i].startsWith('b:')) {
          // C __DATE__ __TIME__ + CMake %z offset: "Mar  1 2026 14:30:00 +0100"
          const raw = parts[i].substring(2);
          const parsed = new Date(raw);
          if (!isNaN(parsed.getTime())) {
            firmwareBuildDate = parsed.toISOString();
          }
        }
      }

      // Parse extra key:value segments (parts[3+]) into a cellular block.
      // Old firmware sends only 3 parts; new cellular firmware sends extras
      // like "uplink:cellular|op:Vodafone DE|rssi:-78|mode:LTE-M|ip:10.0.0.1".
      // parts.slice(3) returns [] when length is 3, so this is a no-op for
      // legacy 3-segment status payloads.
      const cellular: Record<string, string | number> = {};
      for (const seg of parts.slice(3)) {
        const colonIdx = seg.indexOf(':');
        if (colonIdx <= 0) continue;
        const key = seg.slice(0, colonIdx).trim();
        const val = seg.slice(colonIdx + 1).trim();
        if (!key || !val) continue;
        if (key === 'rssi') {
          const n = parseInt(val, 10);
          if (!Number.isNaN(n)) cellular[key] = n;
        } else {
          cellular[key] = val;
        }
      }

      const updatePayload: Record<string, any> = {
        status,
        status_at: new Date().toISOString(),
      };

      // Track when device came online (for uptime calculation).
      // Only set on 'online' — not on offline/ota states which would reset it.
      if (status === 'online') {
        updatePayload.online_since = new Date().toISOString();
      }

      // Only update firmware fields when present (don't clear on offline/ota states)
      if (firmwareVersion) {
        updatePayload.firmware_version = firmwareVersion;
      }
      if (firmwareBuildDate) {
        updatePayload.firmware_build_date = firmwareBuildDate;
      }

      // Merge cellular telemetry into mdb_diagnostics jsonb if present.
      // Read-modify-write so we don't clobber other diagnostic fields the
      // mdb-log handler may have written (state, addr, polls, chkErr, etc).
      if (Object.keys(cellular).length > 0) {
        const { data: existing } = await adminClient
          .from('embeddeds')
          .select('mdb_diagnostics')
          .eq('id', deviceId)
          .maybeSingle();
        const prev = (existing?.mdb_diagnostics as Record<string, unknown> | null) ?? {};
        updatePayload.mdb_diagnostics = { ...prev, cellular };
      }

      const { error } = await adminClient
        .from('embeddeds')
        .update(updatePayload)
        .eq('id', deviceId);

      if (error) throw error;
      return new Response(JSON.stringify({ ok: true }), { status: 200 });
    }

    // MDB diagnostics: plain JSON, no encryption
    // Payload: {"state":"ENABLED","addr":"0x10","polls":1500,"chkErr":0,"lastCmd":"READER_ENABLE"}
    if (eventType === 'mdb-log') {
      const logBytes = decodeBase64(payloadB64);
      const rawJson = new TextDecoder().decode(logBytes);

      let diag: Record<string, unknown>;
      try {
        diag = JSON.parse(rawJson);
      } catch {
        return new Response(JSON.stringify({ error: 'invalid JSON in mdb-log payload' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const newState = diag.state as string | undefined;
      if (!newState) {
        return new Response(JSON.stringify({ error: 'missing state field in mdb-log' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Read current diagnostics to detect state change + check if device is marked online
      const { data: deviceRow, error: fetchErr } = await adminClient
        .from('embeddeds')
        .select('mdb_diagnostics, company, status')
        .eq('id', deviceId)
        .single();

      if (fetchErr) throw fetchErr;
      if (!deviceRow) {
        return new Response(JSON.stringify({ error: 'device not found' }), {
          status: 404,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const prevState = (deviceRow.mdb_diagnostics as Record<string, unknown> | null)?.state as string | undefined;
      const stateChanged = prevState !== newState;

      // Merge diagnostics with previous snapshot so sibling blocks
      // written by other handlers (e.g. cellular telemetry from the
      // status-payload parser) are preserved. Without this merge, every
      // 5-minute mdb-log heartbeat would wipe `cellular`, making the
      // CellularHealthBadge disappear shortly after every reconnect.
      const prevDiag = (deviceRow.mdb_diagnostics as Record<string, unknown> | null) ?? {};
      const diagPayload = { ...prevDiag, ...diag, updated_at: new Date().toISOString() };

      // If device is sending mdb-log, it's clearly online — fix status if
      // the forwarder missed the initial 'online' message (e.g. after server restart)
      const updateFields: Record<string, any> = {
        mdb_diagnostics: diagPayload,
        status_at: new Date().toISOString(),
      };
      if (deviceRow.status !== 'online') {
        updateFields.status = 'online';
        updateFields.online_since = new Date().toISOString();
      }

      const { error: updateErr } = await adminClient
        .from('embeddeds')
        .update(updateFields)
        .eq('id', deviceId);

      if (updateErr) throw updateErr;

      // Insert history row only on state change
      if (stateChanged) {
        const { error: insertErr } = await adminClient
          .from('mdb_log')
          .insert({
            embedded_id: deviceId,
            state: newState,
            prev_state: prevState ?? null,
            addr: (diag.addr as string) ?? null,
            polls: (diag.polls as number) ?? null,
            chk_err: (diag.chkErr as number) ?? null,
            last_cmd: (diag.lastCmd as string) ?? null,
            vmc_level: (diag.vmcLevel as number) ?? null,
            raw: diag,
          });

        if (insertErr) throw insertErr;
      }

      return new Response(JSON.stringify({ ok: true, state_changed: stateChanged }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // Device restart event: plain JSON, no encryption
    // Payload: {"reason":"mqtt_watchdog","uptime":598,"fw":"1.0.0","hw_reason":"SW_CPU_RESET"}
    if (eventType === 'restart') {
      const restartBytes = decodeBase64(payloadB64);
      const rawJson = new TextDecoder().decode(restartBytes);

      let data: Record<string, unknown>;
      try {
        data = JSON.parse(rawJson);
      } catch {
        return new Response(JSON.stringify({ error: 'invalid JSON in restart payload' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      const reason = data.reason as string | undefined;
      if (!reason) {
        return new Response(JSON.stringify({ error: 'missing reason field in restart' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        });
      }

      // Insert restart log entry
      const { error: insertErr } = await adminClient
        .from('device_restarts')
        .insert({
          embedded_id: deviceId,
          reason,
          uptime_sec: (data.uptime as number) ?? null,
          firmware_version: (data.fw as string) ?? null,
          hw_reason: (data.hw_reason as string) ?? null,
          raw: data,
        });

      if (insertErr) throw insertErr;

      // Update embeddeds with latest restart info
      const { error: updateErr } = await adminClient
        .from('embeddeds')
        .update({
          last_restart_reason: reason,
          last_restart_at: new Date().toISOString(),
        })
        .eq('id', deviceId);

      if (updateErr) throw updateErr;

      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // DEX / sale / paxcounter: look up device first (all three need passkey or embedded_id)
    const { data: embeddedData, error: lookupError } = await adminClient
      .from('embeddeds')
      .select('passkey, id, owner_id, company')
      .eq('id', deviceId);

    if (lookupError) throw lookupError;
    if (!embeddedData || embeddedData.length === 0) {
      return new Response(JSON.stringify({ error: 'device not found' }), { status: 404 });
    }

    const embedded = embeddedData[0];

    // DEX telemetry: raw audit bytes, no XOR / no checksum / variable length.
    // Stored for belt-and-suspenders sales reconciliation (see dex_snapshots
    // + dex_reconcile_gaps migration).
    if (eventType === 'dex') {
      const dexBytes = decodeBase64(payloadB64);
      const parsed = parseDexAudit(dexBytes);

      const { error: insertErr } = await adminClient
        .from('dex_snapshots')
        .insert({
          embedded_id: embedded.id,
          raw: `\\x${Array.from(dexBytes).map((b) => b.toString(16).padStart(2, '0')).join('')}`,
          slot_counters: parsed.slot_counters,
          total_vends: parsed.total_vends,
          total_value: parsed.total_value,
        });

      if (insertErr) throw insertErr;
      return new Response(JSON.stringify({ ok: true, slots: Object.keys(parsed.slot_counters).length }), { status: 200 });
    }

    // Sale and paxcounter: encrypted payload
    const payload = new Uint8Array(decodeBase64(payloadB64));

    if (payload.length !== 19) {
      return new Response(JSON.stringify({ error: 'invalid payload length' }), { status: 400 });
    }

    const passkey: number[] = [...embedded.passkey].map((c: string) => c.charCodeAt(0));

    // XOR decrypt bytes 1-18 with passkey
    for (let k = 0; k < passkey.length; k++) {
      payload[k + 1] ^= passkey[k];
    }

    // Validate checksum: sum(bytes 0..17) & 0xFF === byte 18
    const chk = payload.slice(0, -1).reduce((acc, val) => acc + val, 0);
    if (payload[payload.length - 1] !== (chk & 0xff)) {
      return new Response(JSON.stringify({ error: 'checksum mismatch' }), { status: 400 });
    }

    const payloadVersion = payload[1];

    // Extract timestamp (bytes 8-11, big-endian) for use as sale timestamp
    const timestampSec =
      (payload[8] << 24) |
      (payload[9] << 16) |
      (payload[10] << 8) |
      payload[11];
    const timestampUnsigned = timestampSec >>> 0;

    // No timestamp window validation here — this webhook is already authenticated
    // via X-Webhook-Secret, so replay protection is redundant. Skipping the check
    // allows the MQTT broker to queue messages during forwarder downtime.

    if (eventType === 'sale') {
      const cmd = payload[0];
      const itemPrice =
        (payload[2] << 24) |
        (payload[3] << 16) |
        (payload[4] << 8) |
        payload[5];
      const itemNumber = ((payload[6] << 8) | payload[7]) & 0xFFFF;

      // 0x21 = CASH_SALE (coin/bill), 0x23 = CARD_SALE (credit card / cashless device #2), 0x24 = CASHLESS_SALE
      const channel = cmd === 0x23 ? 'card' : cmd === 0x24 ? 'cashless' : 'cash';

      const salePrice = fromScaleFactor(itemPrice >>> 0, 1, 2);

      // Older v1 payloads have no idempotency info — those stay best-effort.
      let saleSeq: number | null = null;
      let timeUncertain = false;
      if (payloadVersion === SALE_PAYLOAD_V2) {
        const flags = payload[12];
        timeUncertain = (flags & 0x01) !== 0;
        saleSeq =
          (payload[14] * 0x1000000) +
          ((payload[15] << 16) | (payload[16] << 8) | payload[17]);
      }

      // Sale time: prefer device clock; if the device flagged `time_uncertain`
      // (SNTP had not synced when the vend happened) fall back to the server
      // receive time. Better to record the sale with a ~outage-length drift
      // than to drop it.
      const saleTime = timeUncertain || timestampUnsigned === 0
        ? new Date().toISOString()
        : new Date(timestampUnsigned * 1000).toISOString();

      // Brownout duplicate guard: a re-reported cash sale after a reboot arrives
      // time_uncertain and re-enqueued with a NEW seq (so the seq idempotency
      // below can't catch it). Only time_uncertain sales are checked, so normal
      // rapid repeat sales are never affected. Window ±SUPPRESS_WINDOW_MS;
      // misses (very slow reconnect) are safe — they fall through to insert and
      // surface as phantoms in the Nayax reconciliation tool.
      if (timeUncertain) {
        const incomingMs = Date.parse(saleTime);
        const { data: candRows } = await adminClient
          .from('sales')
          .select('id, created_at, product_id, time_uncertain')
          .eq('embedded_id', embedded.id)
          .eq('item_number', itemNumber)
          .eq('item_price', salePrice)
          .eq('channel', channel)
          .gte('created_at', new Date(incomingMs - SUPPRESS_WINDOW_MS).toISOString())
          .lte('created_at', new Date(incomingMs + SUPPRESS_WINDOW_MS).toISOString())
          .order('created_at', { ascending: false })
          .limit(20);  // bounded: same-key sales within ±30s are at most a handful
        const candidates: SuppressCandidate[] = (candRows ?? []).map(
          (r: { id: string; created_at: string; product_id: string | null; time_uncertain: boolean | null }) => ({
            id: r.id,
            createdAtMs: Date.parse(r.created_at),
            timeUncertain: r.time_uncertain === true,
          }),
        );
        const matchedId = decideSuppress({ timeUncertain, createdAtMs: incomingMs }, candidates, SUPPRESS_WINDOW_MS);
        if (matchedId) {
          // Reboot-correlation gate: a brownout re-report only follows an
          // actual device reset, so it has a row in device_restarts near the
          // receive time. A genuine repeat purchase on a stable device has
          // none — without a corroborating restart we fall through and insert
          // the sale normally instead of auto-removing it.
          const { data: restartRows } = await adminClient
            .from('device_restarts')
            .select('created_at')
            .eq('embedded_id', embedded.id)
            .gte('created_at', new Date(incomingMs - REBOOT_CORRELATION_WINDOW_MS).toISOString())
            .lte('created_at', new Date(incomingMs + REBOOT_CORRELATION_FORWARD_MS).toISOString())
            .order('created_at', { ascending: false })
            .limit(5);
          const restartMs = (restartRows ?? []).map((r: { created_at: string }) => Date.parse(r.created_at));

          // No nearby reboot → genuine repeat purchase; fall through to the
          // normal sales insert below instead of auto-removing it.
          if (rebootCorroborates(restartMs, incomingMs)) {
            // One original, one re-report. The VMC re-delivers an
            // unacknowledged CASH_SALE exactly once, so a second incoming
            // sale matching an original that already has a suppressed
            // sibling is a genuine repeat purchase, not another re-report.
            // Without this the third, fourth, ... identical sale in a burst
            // would all collapse onto the same surviving row.
            const { data: alreadySuppressed } = await adminClient
              .from('suppressed_sales')
              .select('id')
              .eq('matched_sale_id', matchedId)
              .limit(1);

            if (alreadySuppressed && alreadySuppressed.length > 0) {
              console.log(
                `suppress skipped: sale ${matchedId} already has a suppressed re-report ` +
                `(device=${embedded.id} item=${itemNumber} price=${salePrice} seq=${saleSeq}) — inserting normally`,
              );
            } else {
              const matchedRow = (candRows ?? []).find((r) => r.id === matchedId);
              const { error: suppressErr } = await adminClient.from('suppressed_sales').insert([{
                embedded_id: embedded.id,
                item_number: itemNumber,
                item_price: salePrice,
                channel,
                sale_seq: saleSeq,
                // raw device timestamp, NOT saleTime (which is server time here)
                device_created_at: timestampUnsigned > 0 ? new Date(timestampUnsigned * 1000).toISOString() : null,
                received_at: new Date().toISOString(),
                matched_sale_id: matchedId,
                reason: 'time_uncertain_duplicate',
                product_id: matchedRow?.product_id ?? null,
              }]);
              if (!suppressErr) {
                console.log(
                  `suppressed brownout re-report: device=${embedded.id} item=${itemNumber} ` +
                  `price=${salePrice} channel=${channel} seq=${saleSeq} matched=${matchedId}`,
                );
                return new Response(JSON.stringify({ ok: true, suppressed: true }), { status: 200 });
              }
              console.error('suppressed_sales insert failed; falling through to normal sales insert:', suppressErr);
              // fall through to the existing sales insert below — never drop a real sale silently
            }
          }
        }
      }

      // Idempotency: replays from the device queue / broker retention /
      // forwarder DLQ hit the UNIQUE(embedded_id, sale_seq) index and raise
      // 23505. Treat that as a successful duplicate — the row already
      // exists and the BEFORE INSERT trigger for stock decrement only fires
      // once on the original insert.
      const { error: insertError } = await adminClient
        .from('sales')
        .insert([{
          owner_id: embedded.owner_id,
          embedded_id: embedded.id,
          item_number: itemNumber,
          item_price: salePrice,
          channel,
          created_at: saleTime,
          sale_seq: saleSeq,
          time_uncertain: timeUncertain,
        }]);

      if (insertError) {
        const code = (insertError as { code?: string }).code;
        if (code === '23505') {
          return new Response(JSON.stringify({ ok: true, duplicate: true }), { status: 200 });
        }
        throw insertError;
      }

      // Hoisted out of the push-notification try block below so the
      // activity-log insert further down can also reference them.
      let productName: string | undefined;
      let tray: { product_id: string | null; current_stock: number; min_stock: number; capacity: number; fill_when_below: number } | null = null;

      // ── Push notification dispatch (best-effort, never blocks sale recording) ──
      try {
        // Look up machine + tray + product once (used by both sale and low-stock notifications)
        const { data: machine } = await adminClient
          .from('vendingMachine')
          .select('id, name')
          .eq('embedded', embedded.id)
          .maybeSingle();

        let productImageUrl: string | undefined;
        let lowTray: { current_stock: number; capacity: number } | undefined;

        if (machine) {
          const { data: trayRow } = await adminClient
            .from('machine_trays')
            .select('product_id, current_stock, min_stock, capacity, fill_when_below')
            .eq('machine_id', machine.id)
            .eq('item_number', itemNumber)
            .maybeSingle();
          tray = trayRow;

          if (tray?.product_id) {
            const { data: product } = await adminClient
              .from('products')
              .select('name, image_path')
              .eq('id', tray.product_id)
              .maybeSingle();

            if (product?.name) productName = product.name;
            if (product?.image_path) {
              // Env-var names differ between prod (SUPABASE_PUBLIC_URL) and
              // local dev (PUBLIC_SUPABASE_URL). Fall back to SUPABASE_URL
              // last — that is the internal kong:8000 address in Docker and
              // not reachable from mobile devices.
              const supabaseUrl =
                Deno.env.get('SUPABASE_PUBLIC_URL') ??
                Deno.env.get('PUBLIC_SUPABASE_URL') ??
                Deno.env.get('SUPABASE_URL');
              productImageUrl = `${supabaseUrl}/storage/v1/object/public/product-images/${product.image_path}`;
            }
          }

          if (tray && tray.min_stock > 0 && tray.current_stock <= tray.min_stock) {
            lowTray = { current_stock: tray.current_stock, capacity: tray.capacity ?? tray.min_stock };
          }
        }

        // 1. Sale notification — three-line layout on iOS (title / subtitle /
        //    body), merged on Android+web (subtitle\nbody). Localized per
        //    recipient via sendPushToUsers' locale grouping.
        const itemLabel = productName ?? `Item #${itemNumber}`;
        const machineLabel = machine?.name ? ` · ${machine.name}` : '';

        await sendPushToUsers(adminClient, embedded.company, 'sale', (locale: Locale) => {
          const strings = t(locale);
          const priceStr = formatPrice(salePrice, locale);

          let body: string;
          if (tray && typeof tray.current_stock === 'number' && typeof tray.capacity === 'number' && tray.capacity > 0) {
            const emoji = stockUrgency(tray.current_stock, tray.fill_when_below ?? 0);
            const refillHint = (tray.fill_when_below ?? 0) > 0
              ? ` — ${strings.refillAt(tray.fill_when_below)}`
              : '';
            body = `${emoji}${tray.current_stock}/${tray.capacity} ${strings.left}${refillHint}`;
          } else {
            body = strings.noStockInfo;
          }

          return {
            title: `💵 ${strings.sale}${machineLabel}`,
            subtitle: `${itemLabel} — ${priceStr}`,
            body,
            image: productImageUrl,
            data: { type: 'sale', embedded_id: embedded.id },
          };
        });

        // 2. Low stock notification — localized title + body. Still
        //    suppressed for users with sale enabled (sale push already
        //    carries stock info).
        if (machine && lowTray) {
          const itemLabelLow = productName ?? `Item #${itemNumber}`;
          const machineName = machine.name;

          await sendPushToUsers(adminClient, embedded.company, 'low_stock', (locale: Locale) => {
            const strings = t(locale);
            return {
              title: strings.lowStockTitle,
              body: `${itemLabelLow} in ${machineName}: ${lowTray.current_stock}/${lowTray.capacity} ${strings.remaining}`,
              image: productImageUrl,
              data: { type: 'low_stock', machine_id: machine.id },
            };
          }, {
            suppressIfAlsoEnabled: 'sale',
          });
        }
      } catch (pushErr) {
        console.error('Push notification error:', pushErr);
      }

      // ── Activity log (best-effort) ──────────────────────────────────────────
      try {
        await adminClient.from('activity_log').insert({
          company_id: embedded.company,
          entity_type: 'sale',
          entity_id: embedded.id,
          action: 'sale_recorded',
          metadata: {
            item_number: itemNumber,
            price: salePrice,
            channel,
            device_id: embedded.id,
            product_id: tray?.product_id ?? null,
            product_name: productName ?? null,
            sale_seq: saleSeq,
            time_uncertain: timeUncertain,
          },
        });
      } catch (logErr) {
        console.error('Activity log error:', logErr);
      }
    }

    if (eventType === 'paxcounter') {
      const count = (payload[12] << 8) | payload[13];

      const paxTime = new Date(timestampUnsigned * 1000).toISOString();

      const { error: insertError } = await adminClient
        .from('paxcounter')
        .insert([{
          embedded_id: embedded.id,
          count,
          created_at: paxTime,
        }]);

      if (insertError) throw insertError;
    }

    return new Response(JSON.stringify({ ok: true }), { status: 200 });

  } catch (err) {
    return new Response(JSON.stringify({ error: err?.message ?? err }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
});
