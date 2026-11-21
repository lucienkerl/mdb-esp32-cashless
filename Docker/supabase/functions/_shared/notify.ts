/**
 * One entry point for every notification: sends an event to the members of a
 * company over each channel they turned on for that event type.
 *
 *   notifyUsers(adminClient, companyId, 'machine_offline', (locale) => ({
 *     title, body, link: `/machines/${id}`, data: { type: 'machine_offline' },
 *   }))
 *
 * The message is built once per recipient locale and rendered per channel:
 * push uses it as is (web-push.ts), email renders it via
 * notification-email.ts. Who gets what is decided per channel from
 * `notification_settings` (notification-settings.ts: push defaults on,
 * every other channel is opt-in).
 *
 * Adding a channel: add it to NOTIFICATION_CHANNELS, write a
 * `sendXToUsers(adminClient, companyId, type, build, options)` next to the
 * email one below, call it from notifyUsers, and add the column in the clients.
 */
import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { normalizeLocale, type Locale } from './notification-i18n.ts'
import { renderNotificationEmail } from './notification-email.ts'
import { loadRecipientIds } from './notification-recipients.ts'
import type { NotificationChannel } from './notification-settings.ts'
import { smtpSend, type MailMessage, type SmtpConfig } from './smtp.ts'
import { sendPushToUsers, type PushPayload } from './web-push.ts'

export interface NotificationMessage extends PushPayload {
  /** Where "open" leads: a web-app path ("/machines/<id>") or an absolute URL. */
  link?: string
}

export interface NotifyOptions {
  /** Skip a member who also has this other type on, per channel (see notification-settings.ts). */
  suppressIfAlsoEnabled?: string
  /** Restrict to these channels (default: all). */
  channels?: NotificationChannel[]
  /** Restrict to these users (default: every member of the company). */
  onlyUserIds?: string[]
}

export type NotifyResult = Record<NotificationChannel, { sent: number }>

// ── Email ───────────────────────────────────────────────────────────────────

export interface EmailConfig {
  smtp: SmtpConfig
  fromAddress: string
  fromName: string
  siteUrl?: string
}

/**
 * Email is available when the SMTP server GoTrue uses for the auth mails is
 * configured. Docker/setup.sh writes the placeholder host "supabase-mail" when
 * SMTP was skipped — that counts as not configured.
 */
export function emailConfigFromEnv(env: (k: string) => string | undefined = (k) => Deno.env.get(k)): EmailConfig | null {
  const host = env('SMTP_HOST')?.trim()
  const from = env('SMTP_ADMIN_EMAIL')?.trim()
  if (!host || host === 'supabase-mail' || !from) return null
  const port = parseInt(env('SMTP_PORT') ?? '587', 10)
  const siteUrl = env('SITE_URL')?.trim() || undefined
  let heloName: string | undefined
  try {
    heloName = siteUrl ? new URL(siteUrl).hostname : undefined
  } catch { /* keep default */ }
  return {
    smtp: {
      host,
      port: Number.isFinite(port) ? port : 587,
      user: env('SMTP_USER') || undefined,
      pass: env('SMTP_PASS') || undefined,
      heloName,
    },
    fromAddress: from,
    fromName: env('SMTP_SENDER_NAME')?.trim() || 'VMflow',
    siteUrl,
  }
}

export async function sendEmailToUsers(
  adminClient: SupabaseClient,
  companyId: string,
  notificationType: string,
  build: (locale: Locale) => NotificationMessage,
  options: NotifyOptions = {},
  config: EmailConfig | null = emailConfigFromEnv(),
): Promise<{ sent: number }> {
  if (!config) return { sent: 0 }

  let ids = await loadRecipientIds(adminClient, companyId, notificationType, 'email', options.suppressIfAlsoEnabled)
  if (options.onlyUserIds) {
    const only = new Set(options.onlyUserIds)
    ids = new Set([...ids].filter((id) => only.has(id)))
  }
  if (ids.size === 0) return { sent: 0 }

  const { data: users } = await adminClient
    .from('users')
    .select('id, email, locale')
    .in('id', [...ids])

  const byLocale = new Map<Locale, string[]>()
  for (const u of (users ?? []) as { id: string; email: string | null; locale: string | null }[]) {
    if (!u.email) continue
    const loc = normalizeLocale(u.locale)
    byLocale.set(loc, [...(byLocale.get(loc) ?? []), u.email])
  }

  const messages: MailMessage[] = []
  for (const [locale, addresses] of byLocale) {
    const mail = renderNotificationEmail(build(locale), locale, config.siteUrl)
    for (const to of addresses) {
      messages.push({ fromAddress: config.fromAddress, fromName: config.fromName, to, ...mail })
    }
  }
  if (messages.length === 0) return { sent: 0 }

  const results = await smtpSend(config.smtp, messages)
  for (const r of results) {
    if (!r.ok) console.warn(`[notify] email to ${r.to.replace(/^(.).*@/, '$1…@')} failed: ${r.error}`)
  }
  return { sent: results.filter((r) => r.ok).length }
}

// ── Dispatcher ──────────────────────────────────────────────────────────────

/**
 * Sends `notificationType` over every channel. Never throws: one channel
 * failing (SMTP down, APNs hiccup) must not stop the others nor fail the
 * caller (a sale must be recorded whatever happens to its notification).
 */
export async function notifyUsers(
  adminClient: SupabaseClient,
  companyId: string,
  notificationType: string,
  build: (locale: Locale) => NotificationMessage,
  options: NotifyOptions = {},
): Promise<NotifyResult> {
  const want = (c: NotificationChannel) => !options.channels || options.channels.includes(c)
  const result: NotifyResult = { push: { sent: 0 }, email: { sent: 0 } }

  const tasks: Promise<void>[] = []
  if (want('push')) {
    tasks.push(
      sendPushToUsers(adminClient, companyId, notificationType, build, {
        suppressIfAlsoEnabled: options.suppressIfAlsoEnabled,
      })
        .then((r) => { result.push.sent = r.sent })
        .catch((err) => console.warn(`[notify] push ${notificationType} failed:`, err)),
    )
  }
  if (want('email')) {
    tasks.push(
      sendEmailToUsers(adminClient, companyId, notificationType, build, options)
        .then((r) => { result.email.sent = r.sent })
        .catch((err) => console.warn(`[notify] email ${notificationType} failed:`, err)),
    )
  }
  await Promise.all(tasks)
  return result
}
