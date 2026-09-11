/**
 * Shared MQTT publish helper for edge functions.
 *
 * Speaks MQTT 3.1.1 over a **native** WebSocket rather than through
 * npm:mqtt. The transport has to be WebSocket because the Supabase edge
 * runtime sandboxes Deno.connect() — raw TCP is blocked, but an HTTP upgrade
 * is allowed, and Mosquitto listens for that on port 9001.
 *
 * The library is not usable here though: mqtt.js only takes its native
 * WebSocket path when it detects a *browser* (`window.document`), which no
 * Deno runtime is, and its Node path builds the upgrade with the `ws`
 * package, which sets `options.createConnection` on the request. Deno's node
 * compatibility layer does not implement that option, so every publish died
 * with `Not implemented: ClientRequest.options.createConnection` before a
 * single byte reached the broker — silently taking send-credit, trigger-ota,
 * send-device-config and RFID card credit down with it.
 *
 * Publishing one message is four packets — CONNECT, PUBLISH, PUBACK,
 * DISCONNECT — so we encode them here and depend on nothing.
 */

const MQTT_CONNECT_TIMEOUT_MS = 5_000
const MQTT_PUBACK_TIMEOUT_MS = 5_000

/**
 * Read an env var, treating an empty/whitespace value as absent.
 *
 * `Deno.env.get(x) ?? fallback` only catches undefined. A variable that is
 * declared but resolves to an empty string slips straight through, and the
 * failure is silent and ugly: an unset MQTT_WS_PORT builds `ws://host:`
 * rather than falling back to 9001. That is a live risk for the Supabase CLI
 * dev stack, where config.toml declares MQTT_WS_PORT as env(MQTT_WS_PORT)
 * and nothing guarantees the key exists in Docker/supabase/.env.
 */
function envOr(name: string, fallback: string): string {
  const v = Deno.env.get(name)?.trim()
  return v ? v : fallback
}

// ── Wire format ────────────────────────────────────────────────────────────

const PACKET_CONNECT = 1
const PACKET_CONNACK = 2
const PACKET_PUBLISH = 3
const PACKET_PUBACK = 4
const PACKET_DISCONNECT = 14

/** MQTT's variable-length integer: 7 bits per byte, MSB is the continuation. */
export function encodeRemainingLength(len: number): number[] {
  const out: number[] = []
  let rest = len
  do {
    let byte = rest % 128
    rest = Math.floor(rest / 128)
    if (rest > 0) byte |= 0x80
    out.push(byte)
  } while (rest > 0)
  return out
}

/** Length-prefixed UTF-8, the encoding MQTT uses for every string field. */
function encodeString(str: string): number[] {
  const bytes = new TextEncoder().encode(str)
  if (bytes.length > 0xffff) throw new Error(`MQTT string too long: ${bytes.length} bytes`)
  return [bytes.length >> 8, bytes.length & 0xff, ...bytes]
}

function buildPacket(firstByte: number, body: number[]): Uint8Array {
  const header = [firstByte, ...encodeRemainingLength(body.length)]
  const out = new Uint8Array(header.length + body.length)
  out.set(header, 0)
  out.set(body, header.length)
  return out
}

export function buildConnect(clientId: string, username: string, password: string): Uint8Array {
  let flags = 0x02 // clean session
  if (username) flags |= 0x80
  if (username && password) flags |= 0x40

  const body = [
    ...encodeString('MQTT'),
    0x04, // protocol level 4 = MQTT 3.1.1
    flags,
    0x00,
    0x00, // keep-alive 0: this connection lives for one publish
    ...encodeString(clientId),
  ]
  if (username) body.push(...encodeString(username))
  if (username && password) body.push(...encodeString(password))

  return buildPacket(PACKET_CONNECT << 4, body)
}

export function buildPublish(
  topic: string,
  payload: Uint8Array,
  qos: 0 | 1,
  packetId: number,
): Uint8Array {
  const body = [...encodeString(topic)]
  if (qos > 0) body.push(packetId >> 8, packetId & 0xff)
  body.push(...payload)
  return buildPacket((PACKET_PUBLISH << 4) | (qos << 1), body)
}

interface Packet {
  type: number
  flags: number
  body: Uint8Array
}

/**
 * Incremental packet reader. A broker is free to coalesce several MQTT
 * packets into one WebSocket frame or split one across frames, so the byte
 * stream is reassembled here rather than assuming frame == packet.
 */
export class PacketReader {
  #buf = new Uint8Array(0)

  push(chunk: Uint8Array): void {
    const merged = new Uint8Array(this.#buf.length + chunk.length)
    merged.set(this.#buf, 0)
    merged.set(chunk, this.#buf.length)
    this.#buf = merged
  }

  /** Next complete packet, or null while the stream is still short. */
  next(): Packet | null {
    if (this.#buf.length < 2) return null

    let multiplier = 1
    let remaining = 0
    let i = 1
    let byte: number
    do {
      if (i >= this.#buf.length) return null // length field itself incomplete
      if (i > 4) throw new Error('malformed MQTT remaining length')
      byte = this.#buf[i++]
      remaining += (byte & 0x7f) * multiplier
      multiplier *= 128
    } while (byte & 0x80)

    if (this.#buf.length < i + remaining) return null

    const packet: Packet = {
      type: this.#buf[0] >> 4,
      flags: this.#buf[0] & 0x0f,
      body: this.#buf.slice(i, i + remaining),
    }
    this.#buf = this.#buf.slice(i + remaining)
    return packet
  }
}

/** CONNACK return codes, so a rejected login says so instead of timing out. */
const CONNACK_REASONS: Record<number, string> = {
  1: 'unacceptable protocol version',
  2: 'client id rejected',
  3: 'server unavailable',
  4: 'bad username or password',
  5: 'not authorized',
}

// ── Publish ────────────────────────────────────────────────────────────────

/**
 * Connect to the MQTT broker via WebSocket, publish a message, and disconnect.
 * Throws on connection failure, a rejected login, or timeout.
 */
export async function mqttPublish(
  topic: string,
  payload: string | Uint8Array,
  options?: { qos?: 0 | 1 },
): Promise<void> {
  // Server-side address: always the internal broker, never the public
  // hostname devices use (that one is MQTT_PUBLIC_HOST, and it is only ever
  // handed out by claim-device -- never dialled from here).
  const host = envOr('MQTT_HOST', 'broker')
  const wsPort = envOr('MQTT_WS_PORT', '9001')
  const user = envOr('MQTT_ADMIN_USER', 'admin')
  const pass = envOr('MQTT_ADMIN_PASS', 'admin')

  const url = `ws://${host}:${wsPort}`
  const qos = options?.qos ?? 1
  const bytes = typeof payload === 'string' ? new TextEncoder().encode(payload) : payload

  // Mosquitto's websockets listener speaks the "mqtt" subprotocol; offering
  // it is what tells the broker this is not a browser poking at port 9001.
  const socket = new WebSocket(url, 'mqtt')
  socket.binaryType = 'arraybuffer'

  const reader = new PacketReader()
  const packets: Packet[] = []
  let open = false
  let failure: Error | null = null
  let settled = false
  let wake: (() => void) | null = null

  // Every frame goes through one promise chain so that a runtime handing us
  // Blobs instead of ArrayBuffers cannot reorder the byte stream.
  let ingest: Promise<void> = Promise.resolve()

  socket.onopen = () => {
    open = true
    wake?.()
  }
  socket.onmessage = (ev: MessageEvent) => {
    ingest = ingest.then(async () => {
      const data = ev.data
      let chunk: Uint8Array | null = null
      if (data instanceof ArrayBuffer) chunk = new Uint8Array(data)
      else if (ArrayBuffer.isView(data)) {
        chunk = new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      } else if (data instanceof Blob) chunk = new Uint8Array(await data.arrayBuffer())
      if (!chunk) return // text frames are not MQTT; ignore

      reader.push(chunk)
      for (let p = reader.next(); p !== null; p = reader.next()) packets.push(p)
      wake?.()
    }).catch((err) => {
      failure ??= err instanceof Error ? err : new Error(String(err))
      wake?.()
    })
  }
  socket.onerror = () => {
    failure ??= new Error(`MQTT WebSocket error (${url})`)
    wake?.()
  }
  socket.onclose = (ev: CloseEvent) => {
    if (!settled) {
      failure ??= new Error(
        `MQTT WebSocket closed before the publish completed (code ${ev.code}${ev.reason ? `, ${ev.reason}` : ''})`,
      )
    }
    wake?.()
  }

  /** Resolve as soon as `poll` returns a value; reject on socket failure. */
  function waitFor<T>(poll: () => T | null, timeoutMs: number, what: string): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        wake = null
        reject(new Error(`MQTT timeout waiting for ${what} after ${timeoutMs}ms (${url})`))
      }, timeoutMs)

      const check = () => {
        if (failure) {
          clearTimeout(timer)
          wake = null
          reject(failure)
          return
        }
        const value = poll()
        if (value !== null) {
          clearTimeout(timer)
          wake = null
          resolve(value)
        }
      }

      wake = check
      check()
    })
  }

  const takePacket = (type: number) => (): Packet | null => {
    const i = packets.findIndex((p) => p.type === type)
    return i === -1 ? null : packets.splice(i, 1)[0]
  }

  try {
    await waitFor(() => (open ? true : null), MQTT_CONNECT_TIMEOUT_MS, 'the WebSocket to open')

    const clientId = `vmflow-fn-${crypto.randomUUID().slice(0, 8)}`
    socket.send(buildConnect(clientId, user, pass))

    const connack = await waitFor(takePacket(PACKET_CONNACK), MQTT_CONNECT_TIMEOUT_MS, 'CONNACK')
    const code = connack.body[1]
    if (code !== 0) {
      throw new Error(`MQTT connection refused: ${CONNACK_REASONS[code] ?? `code ${code}`}`)
    }

    const packetId = 1
    socket.send(buildPublish(topic, bytes, qos, packetId))

    if (qos > 0) {
      const puback = await waitFor(takePacket(PACKET_PUBACK), MQTT_PUBACK_TIMEOUT_MS, 'PUBACK')
      const acked = (puback.body[0] << 8) | puback.body[1]
      if (acked !== packetId) {
        throw new Error(`MQTT PUBACK for the wrong packet id: ${acked} (expected ${packetId})`)
      }
    }

    settled = true
    socket.send(buildPacket(PACKET_DISCONNECT << 4, [])) // polite close, no ack
  } finally {
    settled = true
    try {
      socket.close()
    } catch (_) { /* best-effort cleanup */ }
  }
}
