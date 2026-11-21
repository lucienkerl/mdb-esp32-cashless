/**
 * Run: deno test Docker/supabase/functions/_shared/notification-email.test.ts
 */
import { assert, assertEquals, assertStringIncludes } from 'jsr:@std/assert'
import { absoluteLink, renderNotificationEmail } from './notification-email.ts'
import { formatDuration } from './notification-i18n.ts'

Deno.test('subject is the push title, text carries subtitle, body, link and footer', () => {
  const mail = renderNotificationEmail(
    { title: '🔴 Automat offline', subtitle: 'Büro', body: 'Büro ist seit 5 min nicht erreichbar.', link: '/machines/m1' },
    'de',
    'https://app.vmflow.xyz/',
  )
  assertEquals(mail.subject, '🔴 Automat offline')
  assertStringIncludes(mail.text, 'Büro\r\nBüro ist seit 5 min nicht erreichbar.')
  assertStringIncludes(mail.text, 'In VMflow öffnen: https://app.vmflow.xyz/machines/m1')
  assertStringIncludes(mail.text, 'Benachrichtigungen verwalten: https://app.vmflow.xyz/account')
  assertStringIncludes(mail.html, 'href="https://app.vmflow.xyz/machines/m1"')
})

Deno.test('user data is escaped in the HTML part', () => {
  const mail = renderNotificationEmail({ title: '<b>x</b>', body: 'a & "b"' }, 'en', undefined)
  assert(!mail.html.includes('<b>x</b>'))
  assertStringIncludes(mail.html, '&lt;b&gt;x&lt;/b&gt;')
  assertStringIncludes(mail.html, 'a &amp; &quot;b&quot;')
})

Deno.test('without a site URL there is no button and no manage link', () => {
  const mail = renderNotificationEmail({ title: 'T', body: 'B', link: '/machines/m1' }, 'en', undefined)
  assert(!mail.html.includes('href='))
  assert(!mail.text.includes('http'))
})

Deno.test('absoluteLink keeps absolute URLs and joins paths', () => {
  assertEquals(absoluteLink('https://x.y/z', undefined), 'https://x.y/z')
  assertEquals(absoluteLink('machines/1', 'https://a.b'), 'https://a.b/machines/1')
  assertEquals(absoluteLink(undefined, 'https://a.b'), null)
})

Deno.test('formatDuration', () => {
  assertEquals(formatDuration(0.2, 'de'), '1 min')
  assertEquals(formatDuration(5, 'de'), '5 min')
  assertEquals(formatDuration(60, 'en'), '1 h')
  assertEquals(formatDuration(125, 'en'), '2 h 5 min')
  assertEquals(formatDuration(3 * 1440 + 4 * 60, 'de'), '3 Tg. 4 h')
  assertEquals(formatDuration(2 * 1440, 'en'), '2 d')
})
