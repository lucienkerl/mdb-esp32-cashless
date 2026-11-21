import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { normalizeLocale, t } from '../_shared/notification-i18n.ts'
import { renderNotificationEmail } from '../_shared/notification-email.ts'
import { emailConfigFromEnv } from '../_shared/notify.ts'
import { smtpSend } from '../_shared/smtp.ts'

/**
 * notification-channels
 *
 * GET  → which notification channels this server can deliver, for the
 *        settings matrix in the apps:
 *        { channels: [{ key: 'push', available }, { key: 'email', available, address }] }
 * POST { channel: 'email' } → sends a test email to the caller only.
 *
 * Auth: the caller's JWT.
 */
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Authorization, Content-Type, apikey, x-client-info',
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors })
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

  try {
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )
    const token = req.headers.get('Authorization')?.replace(/^Bearer\s+/i, '') ?? ''
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) return json({ error: 'unauthorized' }, 401)

    const { data: profile } = await adminClient
      .from('users')
      .select('email, locale')
      .eq('id', user.id)
      .maybeSingle()
    const address = (profile?.email as string | null) ?? user.email ?? null
    const email = emailConfigFromEnv()

    if (req.method === 'GET') {
      const env = (k: string) => !!Deno.env.get(k)
      const push = (env('VAPID_PUBLIC_KEY') && env('VAPID_PRIVATE_KEY') && env('VAPID_SUBJECT')) ||
        (env('APNS_KEY_ID') && env('APNS_TEAM_ID') && env('APNS_PRIVATE_KEY') && env('APNS_TOPIC')) ||
        env('FCM_SERVICE_ACCOUNT_JSON')
      return json({
        channels: [
          { key: 'push', available: !!push },
          { key: 'email', available: !!email && !!address, configured: !!email, address },
        ],
      })
    }

    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({})) as { channel?: string }
      if (body.channel !== 'email') return json({ error: 'unsupported channel' }, 400)
      if (!email) return json({ error: 'email_not_configured' }, 409)
      if (!address) return json({ error: 'no_email_address' }, 409)

      const locale = normalizeLocale(profile?.locale as string | null)
      const s = t(locale)
      const mail = renderNotificationEmail(
        { title: `✉️ ${s.testEmailTitle}`, body: s.testEmailBody, link: '/account' },
        locale,
        email.siteUrl,
      )
      const [result] = await smtpSend(email.smtp, [
        { fromAddress: email.fromAddress, fromName: email.fromName, to: address, ...mail },
      ])
      if (!result.ok) return json({ error: result.error ?? 'send failed' }, 502)
      return json({ sent: 1, address })
    }

    return json({ error: 'method not allowed' }, 405)
  } catch (err) {
    console.error('[notification-channels]', err)
    return json({ error: err instanceof Error ? err.message : String(err) }, 500)
  }
})
