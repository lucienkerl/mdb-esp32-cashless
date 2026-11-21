/**
 * Minimal SMTP client for the edge functions (Deno), zero dependencies.
 *
 * Why hand-rolled: the edge runtime's Node compatibility layer is incomplete
 * (npm:mqtt died on it, see mqtt-publish.ts), while Deno.connect /
 * Deno.connectTls / Deno.startTls are native and work. The same SMTP server
 * GoTrue already uses for the auth mails (SMTP_* in Docker/.env) sends the
 * notification mails, so there is nothing new to set up.
 *
 * Transport security:
 *  - port 465 → implicit TLS (Deno.connectTls)
 *  - any other port → plain connect, STARTTLS whenever the server offers it
 *  - credentials are never sent over an unencrypted connection: a server that
 *    asks for AUTH but offers no STARTTLS is refused. A server that offers no
 *    AUTH at all (a local mail catcher such as Mailpit) is used without login.
 *
 * Several messages go over one connection (one MAIL/RCPT/DATA per message,
 * one recipient each — recipients never see each other). Tested against an
 * in-process stub server in smtp.test.ts.
 */

export interface SmtpConfig {
  host: string
  port: number
  user?: string
  pass?: string
  /** Name sent in EHLO. */
  heloName?: string
  /** Per-reply timeout in ms (default 15 s). */
  timeoutMs?: number
}

export interface MailMessage {
  fromAddress: string
  fromName?: string
  to: string
  subject: string
  text: string
  html?: string
}

const enc = new TextEncoder()
const dec = new TextDecoder()

// ── MIME ────────────────────────────────────────────────────────────────────

function base64Utf8(s: string): string {
  const bytes = enc.encode(s)
  let bin = ''
  for (const b of bytes) bin += String.fromCharCode(b)
  return btoa(bin)
}

/** RFC 2047 encoded-word for header values that are not plain ASCII. */
export function encodeHeaderValue(value: string): string {
  // deno-lint-ignore no-control-regex
  if (/^[\x20-\x7e]*$/.test(value)) return value
  return `=?UTF-8?B?${base64Utf8(value)}?=`
}

function wrap76(b64: string): string {
  return b64.replace(/.{1,76}/g, (m) => m + '\r\n')
}

/** Strip CR/LF so a value can never inject a header line. */
function headerSafe(v: string): string {
  return v.replace(/[\r\n]+/g, ' ').trim()
}

export function formatAddress(address: string, name?: string): string {
  const addr = headerSafe(address)
  if (!name) return `<${addr}>`
  const n = headerSafe(name)
  const display = /^[\x20-\x7e]*$/.test(n) ? `"${n.replace(/["\\]/g, '')}"` : encodeHeaderValue(n)
  return `${display} <${addr}>`
}

/**
 * Builds the RFC 5322 message (CRLF line endings, bodies base64 so any
 * character set and line length is safe). `boundary`/`date`/`messageId` are
 * injectable for tests.
 */
export function buildMimeMessage(
  msg: MailMessage,
  opts: { date?: Date; messageId?: string; boundary?: string } = {},
): string {
  const date = (opts.date ?? new Date()).toUTCString().replace('GMT', '+0000')
  const domain = msg.fromAddress.split('@')[1] ?? 'localhost'
  const messageId = opts.messageId ?? `<${crypto.randomUUID()}@${domain}>`
  const headers = [
    `From: ${formatAddress(msg.fromAddress, msg.fromName)}`,
    `To: ${formatAddress(msg.to)}`,
    `Subject: ${encodeHeaderValue(headerSafe(msg.subject))}`,
    `Date: ${date}`,
    `Message-ID: ${messageId}`,
    'MIME-Version: 1.0',
    'Auto-Submitted: auto-generated',
  ]

  if (!msg.html) {
    return [
      ...headers,
      'Content-Type: text/plain; charset=UTF-8',
      'Content-Transfer-Encoding: base64',
      '',
      wrap76(base64Utf8(msg.text)),
    ].join('\r\n')
  }

  const boundary = opts.boundary ?? `vmflow-${crypto.randomUUID()}`
  return [
    ...headers,
    `Content-Type: multipart/alternative; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    wrap76(base64Utf8(msg.text)),
    `--${boundary}`,
    'Content-Type: text/html; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
    '',
    wrap76(base64Utf8(msg.html)),
    `--${boundary}--`,
    '',
  ].join('\r\n')
}

/** SMTP transparency (RFC 5321 4.5.2): a line starting with "." gets one more. */
export function dotStuff(data: string): string {
  return data.replace(/\r\n\./g, '\r\n..').replace(/^\./, '..')
}

// ── Protocol ────────────────────────────────────────────────────────────────

interface Reply {
  code: number
  lines: string[]
}

class SmtpConnection {
  private buf = ''
  constructor(private conn: Deno.Conn, private timeoutMs: number) {}

  setConn(conn: Deno.Conn) {
    this.conn = conn
    this.buf = ''
  }

  async readReply(): Promise<Reply> {
    const lines: string[] = []
    const deadline = Date.now() + this.timeoutMs
    while (true) {
      const nl = this.buf.indexOf('\r\n')
      if (nl >= 0) {
        const line = this.buf.slice(0, nl)
        this.buf = this.buf.slice(nl + 2)
        lines.push(line.slice(4))
        if (line.length < 4 || line[3] === ' ') {
          const code = parseInt(line.slice(0, 3), 10)
          if (Number.isNaN(code)) throw new Error(`SMTP: malformed reply "${line}"`)
          return { code, lines }
        }
        continue
      }
      const chunk = new Uint8Array(4096)
      const remaining = deadline - Date.now()
      if (remaining <= 0) throw new Error('SMTP: reply timed out')
      let timer: ReturnType<typeof setTimeout> | undefined
      const n = await Promise.race([
        this.conn.read(chunk),
        new Promise<never>((_, rej) => {
          timer = setTimeout(() => rej(new Error('SMTP: reply timed out')), remaining)
        }),
      ]).finally(() => clearTimeout(timer))
      if (n === null) throw new Error('SMTP: connection closed by server')
      this.buf += dec.decode(chunk.subarray(0, n))
    }
  }

  async write(s: string) {
    const bytes = enc.encode(s)
    let off = 0
    while (off < bytes.length) off += await this.conn.write(bytes.subarray(off))
  }

  async command(line: string, expect: number[]): Promise<Reply> {
    await this.write(line + '\r\n')
    const reply = await this.readReply()
    if (!expect.includes(reply.code)) {
      const shown = line.startsWith('AUTH') ? 'AUTH …' : line
      throw new Error(`SMTP: "${shown}" answered ${reply.code} ${reply.lines.join(' ')}`)
    }
    return reply
  }
}

function capabilities(ehlo: Reply): { starttls: boolean; auth: string[] } {
  let starttls = false
  let auth: string[] = []
  for (const l of ehlo.lines) {
    const u = l.toUpperCase()
    if (u === 'STARTTLS') starttls = true
    if (u.startsWith('AUTH ') || u.startsWith('AUTH=')) auth = u.slice(5).split(/\s+/)
  }
  return { starttls, auth }
}

/**
 * Sends every message over one connection. Resolves with the per-message
 * outcome; a rejected recipient does not stop the others. Throws only when the
 * connection itself cannot be established or authenticated.
 */
export async function smtpSend(
  config: SmtpConfig,
  messages: MailMessage[],
  deps: {
    connect?: (o: { hostname: string; port: number }) => Promise<Deno.Conn>
    connectTls?: (o: { hostname: string; port: number }) => Promise<Deno.Conn>
    startTls?: (c: Deno.Conn, o: { hostname: string }) => Promise<Deno.Conn>
  } = {},
): Promise<{ to: string; ok: boolean; error?: string }[]> {
  if (messages.length === 0) return []
  const connect = deps.connect ?? ((o) => Deno.connect(o))
  const connectTls = deps.connectTls ?? ((o) => Deno.connectTls(o))
  const startTls = deps.startTls ?? ((c, o) => Deno.startTls(c as Deno.TcpConn, o))

  const implicitTls = config.port === 465
  let conn = implicitTls
    ? await connectTls({ hostname: config.host, port: config.port })
    : await connect({ hostname: config.host, port: config.port })
  let encrypted = implicitTls
  const smtp = new SmtpConnection(conn, config.timeoutMs ?? 15000)
  const helo = config.heloName ?? 'vmflow.local'
  const results: { to: string; ok: boolean; error?: string }[] = []

  try {
    const greeting = await smtp.readReply()
    if (greeting.code !== 220) throw new Error(`SMTP: greeting ${greeting.code}`)

    let caps = capabilities(await smtp.command(`EHLO ${helo}`, [250]))

    if (!encrypted && caps.starttls) {
      await smtp.command('STARTTLS', [220])
      conn = await startTls(conn, { hostname: config.host })
      smtp.setConn(conn)
      encrypted = true
      caps = capabilities(await smtp.command(`EHLO ${helo}`, [250]))
    }

    if (config.user && caps.auth.length > 0) {
      if (!encrypted) {
        throw new Error('SMTP: server wants a login but offers no STARTTLS — refusing to send the password unencrypted')
      }
      if (caps.auth.includes('PLAIN')) {
        await smtp.command(`AUTH PLAIN ${base64Utf8(`\0${config.user}\0${config.pass ?? ''}`)}`, [235])
      } else if (caps.auth.includes('LOGIN')) {
        await smtp.command('AUTH LOGIN', [334])
        await smtp.command(base64Utf8(config.user), [334])
        await smtp.command(base64Utf8(config.pass ?? ''), [235])
      } else {
        throw new Error(`SMTP: no supported AUTH mechanism (${caps.auth.join(' ')})`)
      }
    }

    for (const msg of messages) {
      try {
        await smtp.command(`MAIL FROM:<${headerSafe(msg.fromAddress)}>`, [250])
        await smtp.command(`RCPT TO:<${headerSafe(msg.to)}>`, [250, 251])
        await smtp.command('DATA', [354])
        const data = dotStuff(buildMimeMessage(msg))
        await smtp.command(`${data.endsWith('\r\n') ? data : data + '\r\n'}.`, [250])
        results.push({ to: msg.to, ok: true })
      } catch (err) {
        results.push({ to: msg.to, ok: false, error: err instanceof Error ? err.message : String(err) })
        // Bring the session back to a clean state for the next message.
        await smtp.command('RSET', [250]).catch(() => {})
      }
    }

    await smtp.command('QUIT', [221]).catch(() => {})
  } finally {
    try { conn.close() } catch { /* already closed */ }
  }
  return results
}
