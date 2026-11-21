/**
 * Run: deno test -A Docker/supabase/functions/_shared/smtp.test.ts
 *
 * Drives smtpSend against an in-process stub SMTP server (plain TCP). The
 * stub parses the conversation itself, so a framing bug in the client can't
 * be hidden by the same bug in the test. STARTTLS is simulated by injecting a
 * startTls that hands back the same (plain) socket.
 */
import { assert, assertEquals, assertRejects, assertStringIncludes } from 'jsr:@std/assert'
import { buildMimeMessage, dotStuff, encodeHeaderValue, smtpSend, type MailMessage } from './smtp.ts'

interface StubOptions {
  starttls?: boolean
  auth?: boolean
  rejectRcpt?: string
}

interface Stub {
  port: number
  commands: string[]
  messages: { from: string; to: string; data: string }[]
  stop: () => void
}

function startStub(opts: StubOptions = {}): Stub {
  const listener = Deno.listen({ hostname: '127.0.0.1', port: 0 })
  const commands: string[] = []
  const messages: { from: string; to: string; data: string }[] = []
  const enc = new TextEncoder()
  const dec = new TextDecoder()

  ;(async () => {
    for await (const conn of listener) {
      ;(async () => {
        const send = (s: string) => conn.write(enc.encode(s + '\r\n'))
        await send('220 stub ESMTP')
        let buf = ''
        let inData = false
        let data = ''
        let from = ''
        let to = ''
        const chunk = new Uint8Array(4096)
        while (true) {
          const n = await conn.read(chunk).catch(() => null)
          if (n === null) break
          buf += dec.decode(chunk.subarray(0, n))
          let nl: number
          while ((nl = buf.indexOf('\r\n')) >= 0) {
            const line = buf.slice(0, nl)
            buf = buf.slice(nl + 2)
            if (inData) {
              if (line === '.') {
                inData = false
                messages.push({ from, to, data })
                data = ''
                await send('250 queued')
              } else {
                data += (line.startsWith('..') ? line.slice(1) : line) + '\r\n'
              }
              continue
            }
            commands.push(line)
            const u = line.toUpperCase()
            if (u.startsWith('EHLO')) {
              const caps = ['250-stub']
              if (opts.starttls) caps.push('250-STARTTLS')
              if (opts.auth) caps.push('250-AUTH PLAIN LOGIN')
              caps.push('250 8BITMIME')
              await send(caps.join('\r\n'))
            } else if (u === 'STARTTLS') await send('220 go ahead')
            else if (u.startsWith('AUTH PLAIN')) {
              const decoded = atob(line.slice(11))
              await send(decoded === '\0user\0secret' ? '235 ok' : '535 bad credentials')
            } else if (u.startsWith('MAIL FROM:')) { from = line.slice(10); await send('250 ok') }
            else if (u.startsWith('RCPT TO:')) {
              to = line.slice(8)
              await send(opts.rejectRcpt && to.includes(opts.rejectRcpt) ? '550 no such user' : '250 ok')
            } else if (u === 'DATA') { inData = true; await send('354 end with .') }
            else if (u === 'RSET') await send('250 reset')
            else if (u === 'QUIT') { await send('221 bye'); conn.close(); return }
            else await send('500 unknown')
          }
        }
      })()
    }
  })().catch(() => {})

  return {
    port: (listener.addr as Deno.NetAddr).port,
    commands,
    messages,
    stop: () => listener.close(),
  }
}

const msg = (to: string, extra: Partial<MailMessage> = {}): MailMessage => ({
  fromAddress: 'noreply@vmflow.xyz',
  fromName: 'VMflow',
  to,
  subject: 'Automat offline: Büro',
  text: 'Line one\r\n.starts with a dot',
  html: '<p>Hallo</p>',
  ...extra,
})

const plainTls = { startTls: (c: Deno.Conn) => Promise.resolve(c) }

Deno.test('sends several messages over one connection, no login on an AUTH-less server', async () => {
  const stub = startStub()
  try {
    const res = await smtpSend({ host: '127.0.0.1', port: stub.port, user: 'user', pass: 'secret' }, [
      msg('a@test.local'),
      msg('b@test.local'),
    ])
    assertEquals(res.map((r) => r.ok), [true, true])
    assertEquals(stub.messages.length, 2)
    assertEquals(stub.messages[0].to, '<a@test.local>')
    assertEquals(stub.messages[1].to, '<b@test.local>')
    assert(!stub.commands.some((c) => c.startsWith('AUTH')), 'no AUTH when the server offers none')
    assertEquals(stub.commands.filter((c) => c.startsWith('EHLO')).length, 1)
    assertEquals(stub.commands.at(-1), 'QUIT')
  } finally {
    stub.stop()
  }
})

Deno.test('STARTTLS before AUTH PLAIN, EHLO repeated after the upgrade', async () => {
  const stub = startStub({ starttls: true, auth: true })
  try {
    const res = await smtpSend(
      { host: '127.0.0.1', port: stub.port, user: 'user', pass: 'secret' },
      [msg('a@test.local')],
      plainTls,
    )
    assertEquals(res[0].ok, true)
    const order = stub.commands.map((c) => c.split(' ')[0].toUpperCase())
    assertEquals(order.slice(0, 4), ['EHLO', 'STARTTLS', 'EHLO', 'AUTH'])
  } finally {
    stub.stop()
  }
})

Deno.test('refuses to send a password over a connection without STARTTLS', async () => {
  const stub = startStub({ auth: true })
  try {
    await assertRejects(
      () => smtpSend({ host: '127.0.0.1', port: stub.port, user: 'user', pass: 'secret' }, [msg('a@test.local')]),
      Error,
      'unencrypted',
    )
    assert(!stub.commands.some((c) => c.startsWith('AUTH')))
  } finally {
    stub.stop()
  }
})

Deno.test('bad credentials throw', async () => {
  const stub = startStub({ starttls: true, auth: true })
  try {
    await assertRejects(
      () => smtpSend({ host: '127.0.0.1', port: stub.port, user: 'user', pass: 'wrong' }, [msg('a@test.local')], plainTls),
      Error,
      '535',
    )
  } finally {
    stub.stop()
  }
})

Deno.test('a rejected recipient does not stop the next one', async () => {
  const stub = startStub({ rejectRcpt: 'bad@' })
  try {
    const res = await smtpSend({ host: '127.0.0.1', port: stub.port }, [msg('bad@test.local'), msg('good@test.local')])
    assertEquals(res.map((r) => r.ok), [false, true])
    assertStringIncludes(res[0].error ?? '', '550')
    assertEquals(stub.messages.length, 1)
    assert(stub.commands.includes('RSET'))
  } finally {
    stub.stop()
  }
})

Deno.test('body survives dot-stuffing and base64 round trip', async () => {
  const stub = startStub()
  try {
    await smtpSend({ host: '127.0.0.1', port: stub.port }, [msg('a@test.local', { html: undefined })])
    const data = stub.messages[0].data
    const body = data.split('\r\n\r\n')[1].replace(/\r\n/g, '')
    const text = new TextDecoder().decode(Uint8Array.from(atob(body), (c) => c.charCodeAt(0)))
    assertEquals(text, 'Line one\r\n.starts with a dot')
    assertStringIncludes(data, `Subject: ${encodeHeaderValue('Automat offline: Büro')}`)
  } finally {
    stub.stop()
  }
})

Deno.test('MIME: multipart with both parts, header injection stripped', () => {
  const mime = buildMimeMessage(
    msg('a@test.local', { subject: 'Hi\r\nBcc: evil@x' }),
    { date: new Date('2026-11-21T12:00:00Z'), messageId: '<id@vmflow.xyz>', boundary: 'B' },
  )
  assertStringIncludes(mime, 'Content-Type: multipart/alternative; boundary="B"')
  assertStringIncludes(mime, '--B\r\nContent-Type: text/plain; charset=UTF-8')
  assertStringIncludes(mime, '--B\r\nContent-Type: text/html; charset=UTF-8')
  assertStringIncludes(mime, '--B--')
  assertStringIncludes(mime, 'Subject: Hi Bcc: evil@x')
  assert(!mime.includes('\r\nBcc:'))
  assertStringIncludes(mime, 'From: "VMflow" <noreply@vmflow.xyz>')
  assertStringIncludes(mime, 'Date: Sat, 21 Nov 2026 12:00:00 +0000')
})

Deno.test('dotStuff doubles leading dots only', () => {
  assertEquals(dotStuff('.a\r\nb.\r\n.c'), '..a\r\nb.\r\n..c')
})
