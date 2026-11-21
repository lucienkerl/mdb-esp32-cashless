/**
 * Renders a notification (the same message the push gets) as an email.
 *
 * Every event type gets an email for free: subject = push title, text =
 * subtitle + body, plus a button into the app and a footer that says why the
 * mail came and where to switch it off. Pure; tested in
 * notification-email.test.ts.
 */
import { t, type Locale } from './notification-i18n.ts'

export interface EmailSource {
  title: string
  subtitle?: string
  body: string
  image?: string
  /** Path in the web app (e.g. "/machines/<id>") or an absolute URL. */
  link?: string
}

export interface RenderedEmail {
  subject: string
  text: string
  html: string
}

export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

/** Absolute URL for a link, or null when there is no usable site URL. */
export function absoluteLink(link: string | undefined, siteUrl: string | undefined): string | null {
  if (!link) return null
  if (/^https?:\/\//i.test(link)) return link
  if (!siteUrl) return null
  return siteUrl.replace(/\/+$/, '') + (link.startsWith('/') ? link : `/${link}`)
}

export function renderNotificationEmail(
  msg: EmailSource,
  locale: Locale,
  siteUrl: string | undefined,
): RenderedEmail {
  const s = t(locale)
  const open = absoluteLink(msg.link, siteUrl)
  const manage = absoluteLink('/account', siteUrl)
  const lines = [msg.subtitle, msg.body].filter((l): l is string => !!l && l.trim().length > 0)

  const text = [
    ...lines,
    '',
    ...(open ? [`${s.emailOpen}: ${open}`, ''] : []),
    '—',
    s.emailFooter,
    ...(manage ? [`${s.emailManage}: ${manage}`] : []),
  ].join('\r\n')

  const para = (l: string) =>
    `<p style="margin:0 0 8px;font-size:15px;line-height:1.5;color:#111827">${escapeHtml(l).replace(/\r?\n/g, '<br>')}</p>`
  const image = msg.image && /^https?:\/\//i.test(msg.image)
    ? `<img src="${escapeHtml(msg.image)}" alt="" width="96" style="display:block;width:96px;height:auto;border-radius:8px;margin:0 0 16px">`
    : ''
  const button = open
    ? `<p style="margin:20px 0 0"><a href="${escapeHtml(open)}" style="display:inline-block;background:#111827;color:#ffffff;text-decoration:none;padding:10px 16px;border-radius:8px;font-size:14px;font-weight:600">${escapeHtml(s.emailOpen)}</a></p>`
    : ''
  const manageLink = manage
    ? ` <a href="${escapeHtml(manage)}" style="color:#6b7280">${escapeHtml(s.emailManage)}</a>`
    : ''

  const html = `<!doctype html>
<html lang="${locale}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(msg.title)}</title></head>
<body style="margin:0;padding:0;background:#f3f4f6;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f6;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:12px;padding:24px">
<tr><td>
<h1 style="margin:0 0 16px;font-size:18px;line-height:1.3;color:#111827">${escapeHtml(msg.title)}</h1>
${image}${lines.map(para).join('\n')}${button}
</td></tr></table>
<p style="max-width:520px;margin:16px auto 0;font-size:12px;line-height:1.5;color:#6b7280">${escapeHtml(s.emailFooter)}${manageLink}</p>
</td></tr></table>
</body></html>`

  return { subject: msg.title, text, html }
}
