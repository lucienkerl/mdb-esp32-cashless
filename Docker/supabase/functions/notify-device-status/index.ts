import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { formatDuration, t, type Locale } from '../_shared/notification-i18n.ts'
import { notifyUsers } from '../_shared/notify.ts'

/**
 * notify-device-status
 *
 * Sends the "machine offline" / "machine back online" notifications over the
 * channels each member chose. Called only by the pg_cron dispatcher
 * `dispatch_device_connectivity_alerts()` (migration
 * 20261121120000_notification_channels.sql), which decides WHEN: offline only
 * after companies.offline_alert_minutes, back online only after an alerted
 * outage. This function only phrases and sends.
 *
 * Body: { embedded_id: uuid, event: 'offline' | 'online' }
 * Auth: Bearer <service role key>
 */
Deno.serve(async (req) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })

  if (req.method !== 'POST') return json({ error: 'method not allowed' }, 405)

  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? ''
  if (!token || token !== serviceKey) return json({ error: 'unauthorized' }, 401)

  const body = await req.json().catch(() => ({})) as { embedded_id?: unknown; event?: unknown }
  const embeddedId = typeof body.embedded_id === 'string' ? body.embedded_id : null
  const event = body.event === 'offline' || body.event === 'online' ? body.event : null
  if (!embeddedId || !event) return json({ error: 'embedded_id and event (offline|online) required' }, 400)

  try {
    const adminClient = createClient(Deno.env.get('SUPABASE_URL')!, serviceKey)

    const { data: device } = await adminClient
      .from('embeddeds')
      .select('id, company, name, subdomain, status, status_at')
      .eq('id', embeddedId)
      .maybeSingle()
    if (!device?.company) return json({ error: 'device not found' }, 404)

    const { data: machine } = await adminClient
      .from('vendingMachine')
      .select('id, name')
      .eq('embedded', embeddedId)
      .maybeSingle()

    // How long the outage lasted (online) / has lasted so far (offline).
    let since: string | null = event === 'offline' ? device.status_at : null
    if (event === 'online') {
      const { data: lastOffline } = await adminClient
        .from('embedded_status_log')
        .select('created_at')
        .eq('embedded_id', embeddedId)
        .eq('status', 'offline')
        .order('created_at', { ascending: false })
        .limit(1)
        .maybeSingle()
      since = lastOffline?.created_at ?? null
    }
    const minutes = since ? (Date.now() - new Date(since).getTime()) / 60000 : null

    const label = (machine?.name as string | null) ??
      (device.name as string | null) ??
      (device.subdomain != null ? `#${device.subdomain}` : null)
    const type = event === 'offline' ? 'machine_offline' : 'machine_online'

    const result = await notifyUsers(adminClient, device.company, type, (locale: Locale) => {
      const s = t(locale)
      const name = label ?? s.unknownMachine
      const duration = minutes != null ? formatDuration(minutes, locale) : '?'
      return {
        title: event === 'offline' ? `🔴 ${s.machineOfflineTitle}` : `🟢 ${s.machineOnlineTitle}`,
        body: event === 'offline' ? s.machineOfflineBody(name, duration) : s.machineOnlineBody(name, duration),
        link: machine ? `/machines/${machine.id}` : '/devices',
        data: { type, machine_id: machine?.id ?? null, embedded_id: embeddedId },
      }
    })

    return json({ ok: true, ...result })
  } catch (err) {
    console.error('[notify-device-status]', err)
    return json({ error: err instanceof Error ? err.message : String(err) }, 500)
  }
})
