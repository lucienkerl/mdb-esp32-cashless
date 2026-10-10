import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { mqttPublish } from '../_shared/mqtt-publish.ts'
import {
  buildConfigPayload,
  CMD_MDB_ADDRESS,
  CMD_MDB_RESET,
  CMD_MDB_TRACE,
  CMD_RESTART,
  MDB_TRACE_MAX_SECONDS,
} from '../_shared/config-payload.ts'

Deno.serve(async (req) => {
  try {
    const body = await req.json()
    const { device_id, config } = body

    if (!device_id || !config || typeof config !== 'object') {
      return new Response(JSON.stringify({ error: 'device_id and config are required' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Validate config values ──────────────────────────────────────────────
    const dbUpdate: Record<string, unknown> = {}
    const configActions: { cmd: number; param: number; item?: number; label: string; summary: unknown }[] = []

    if (config.mdb_address !== undefined) {
      if (config.mdb_address !== 1 && config.mdb_address !== 2) {
        return new Response(JSON.stringify({ error: 'mdb_address must be 1 or 2' }), {
          status: 400, headers: { 'Content-Type': 'application/json' },
        })
      }
      dbUpdate.mdb_address = config.mdb_address
      configActions.push({ cmd: CMD_MDB_ADDRESS, param: config.mdb_address, label: 'mdb_address', summary: config.mdb_address })
    }

    // Remote restart — no DB update needed
    if (config.restart === true) {
      configActions.push({ cmd: CMD_RESTART, param: 0, label: 'restart', summary: true })
    }

    // MDB soft reset — device announces "Just Reset" on next POLL, VMC re-runs SETUP
    if (config.mdb_reset === true) {
      configActions.push({ cmd: CMD_MDB_RESET, param: 0, label: 'mdb_reset', summary: true })
    }

    // Live MDB bus trace — value is the number of seconds to trace (the device
    // stops by itself), 0 stops a running trace. Debug output costs uplink
    // traffic, hence the cap (the firmware enforces the same one).
    if (config.mdb_trace !== undefined) {
      const seconds = config.mdb_trace
      if (!Number.isInteger(seconds) || seconds < 0 || seconds > MDB_TRACE_MAX_SECONDS) {
        return new Response(JSON.stringify({ error: `mdb_trace must be an integer number of seconds between 0 and ${MDB_TRACE_MAX_SECONDS}` }), {
          status: 400, headers: { 'Content-Type': 'application/json' },
        })
      }
      configActions.push({ cmd: CMD_MDB_TRACE, param: 0, item: seconds, label: 'mdb_trace', summary: seconds })
    }

    if (configActions.length === 0) {
      return new Response(JSON.stringify({ error: 'No valid config keys provided' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Authenticate caller ─────────────────────────────────────────────────
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const authHeader = req.headers.get('Authorization')
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Authorization required' }), {
        status: 401, headers: { 'Content-Type': 'application/json' },
      })
    }

    const token = authHeader.replace('Bearer ', '')
    const companyIdHeader = req.headers.get('X-Company-Id')
    let companyId: string | null = null
    let userId: string | null = null

    // Path 1: Service-role call from API gateway
    if (token === Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') && companyIdHeader) {
      companyId = companyIdHeader
    } else {
      // Path 2: Normal user JWT
      const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'Unauthorized' }), {
          status: 401, headers: { 'Content-Type': 'application/json' },
        })
      }
      userId = user.id

      const { data: membership } = await adminClient
        .from('organization_members')
        .select('company_id, role')
        .eq('user_id', user.id)
        .maybeSingle()

      if (!membership || membership.role !== 'admin') {
        return new Response(JSON.stringify({ error: 'Admin role required' }), {
          status: 403, headers: { 'Content-Type': 'application/json' },
        })
      }
      companyId = membership.company_id
    }

    // ── Look up device (with passkey for XOR encryption) ────────────────────
    const { data: device, error: deviceError } = await adminClient
      .from('embeddeds')
      .select('id, company, status, passkey')
      .eq('id', device_id)
      .eq('company', companyId)
      .maybeSingle()

    if (deviceError || !device) {
      return new Response(JSON.stringify({ error: 'Device not found or not in your organization' }), {
        status: 404, headers: { 'Content-Type': 'application/json' },
      })
    }

    if (!device.passkey) {
      return new Response(JSON.stringify({ error: 'Device has no passkey configured' }), {
        status: 400, headers: { 'Content-Type': 'application/json' },
      })
    }

    // ── Update DB (skip if only restart, no persistent config changes) ──────
    if (Object.keys(dbUpdate).length > 0) {
      const { error: updateError } = await adminClient
        .from('embeddeds')
        .update(dbUpdate)
        .eq('id', device.id)

      if (updateError) throw updateError
    }

    // ── Publish XOR-encrypted config to MQTT ────────────────────────────────
    const topic = `/${device.company}/${device.id}/config`

    // Send each config action as a separate encrypted message
    for (const action of configActions) {
      const payload = buildConfigPayload(action.cmd, action.param, device.passkey, action.item ?? 0)
      await mqttPublish(topic, payload, { qos: 1 })
    }

    // ── Activity log (best-effort) ──────────────────────────────────────────
    const configSummary = Object.fromEntries(
      configActions.map(a => [a.label, a.summary])
    )
    try {
      await adminClient.from('activity_log').insert({
        company_id: device.company,
        user_id: userId,
        entity_type: 'device',
        entity_id: device.id,
        action: 'config_updated',
        metadata: { config: configSummary },
      })
    } catch (_) { /* best-effort */ }

    return new Response(JSON.stringify({
      status: device.status,
      config: configSummary,
    }), {
      headers: { 'Content-Type': 'application/json' },
    })

  } catch (err) {
    return new Response(JSON.stringify({ error: err?.message ?? err }), {
      status: 500, headers: { 'Content-Type': 'application/json' },
    })
  }
})
