/**
 * Live MDB bus trace — pure logic behind the debug console on /machines/[id].
 *
 * The firmware (mdb-slave-esp32s3/main/mdb_trace.h) publishes batches of raw
 * 9-bit MDB words; mqtt-webhook stores one `mdb_trace` row per batch. This
 * module turns those rows into console lines and annotates them with what the
 * words mean (MDB 4.2: address table, cashless commands and replies), without
 * touching Vue or Supabase so it stays unit-testable.
 *
 * A "word" is one 9-bit MDB character: bits 0-7 data, bit 8 the mode bit. The
 * mode bit marks an address byte coming from the VMC, and the checksum byte of
 * a peripheral reply (an ACK is therefore the single word 0x100).
 */

export type TraceDir = 'rx' | 'tx'

/** One frame as stored in `mdb_trace.frames`: [age_ms, "r"|"t", "<3-digit hex words>"]. */
export type RawFrame = [ageMs: number, dir: 'r' | 't', words: string]

export interface MdbTraceRow {
  id: number | string
  created_at: string
  embedded_id: string
  frames: RawFrame[]
  dropped: number
}

export interface TraceFrameEntry {
  kind: 'frame'
  id: string
  /** Wall-clock ms: the batch's arrival time minus the frame's age. */
  time: number
  dir: TraceDir
  /** 9-bit MDB words, bit 8 = mode bit. */
  words: number[]
}

/** The device lost words (capture ring overflowed) just before this point. */
export interface TraceGapEntry {
  kind: 'gap'
  id: string
  time: number
  dropped: number
}

export type TraceEntry = TraceFrameEntry | TraceGapEntry

export const MODE_BIT = 0x100

// ── Rows → entries ───────────────────────────────────────────────────────────

/** "112012" → [0x112, 0x012]. Anything that is not whole 3-digit hex words is dropped. */
export function parseWords(hex: string): number[] {
  if (!/^[0-9A-Fa-f]+$/.test(hex) || hex.length % 3 !== 0) return []
  const words: number[] = []
  for (let i = 0; i < hex.length; i += 3) {
    const w = parseInt(hex.slice(i, i + 3), 16)
    if (w > 0x1ff) return []
    words.push(w)
  }
  return words
}

/** Expand one stored batch into console entries, oldest first. */
export function rowToEntries(row: MdbTraceRow): TraceEntry[] {
  const arrival = Date.parse(row.created_at)
  if (Number.isNaN(arrival) || !Array.isArray(row.frames)) return []

  const entries: TraceEntry[] = []

  if (row.dropped > 0) {
    // The loss happened before this batch's first frame; there is no better
    // timestamp than that frame's, so the marker sorts right in front of it.
    const firstAge = Array.isArray(row.frames[0]) ? Number(row.frames[0][0]) || 0 : 0
    entries.push({ kind: 'gap', id: `${row.id}:gap`, time: arrival - firstAge, dropped: row.dropped })
  }

  row.frames.forEach((frame, i) => {
    if (!Array.isArray(frame) || frame.length !== 3) return
    const words = parseWords(String(frame[2]))
    if (words.length === 0) return
    entries.push({
      kind: 'frame',
      id: `${row.id}:${i}`,
      time: arrival - (Number(frame[0]) || 0),
      dir: frame[1] === 't' ? 'tx' : 'rx',
      words,
    })
  })

  return entries
}

// ── MDB vocabulary (MDB/ICP 4.2) ─────────────────────────────────────────────

const DEVICE_NAMES: Record<number, string> = {
  0x08: 'Changer',
  0x10: 'Cashless #1',
  0x18: 'Comms gateway',
  0x20: 'Display',
  0x28: 'Energy mgmt',
  0x30: 'Bill validator',
  0x40: 'USD #1',
  0x48: 'USD #2',
  0x50: 'USD #3',
  0x58: 'Hopper #1',
  0x60: 'Cashless #2',
  0x68: 'Age verification',
  0x70: 'Hopper #2',
}

const CASHLESS_ADDRESSES = new Set([0x10, 0x60])

const CASHLESS_COMMANDS: Record<number, string> = {
  0: 'RESET', 1: 'SETUP', 2: 'POLL', 3: 'VEND', 4: 'READER', 5: 'REVALUE', 7: 'EXPANSION',
}
const CHANGER_COMMANDS: Record<number, string> = {
  0: 'RESET', 1: 'SETUP', 2: 'TUBE STATUS', 3: 'POLL', 4: 'COIN TYPE', 5: 'DISPENSE', 7: 'EXPANSION',
}
const BILL_COMMANDS: Record<number, string> = {
  0: 'RESET', 1: 'SETUP', 2: 'SECURITY', 3: 'POLL', 4: 'BILL TYPE', 5: 'ESCROW', 6: 'STACKER', 7: 'EXPANSION',
}

const SETUP_SUB: Record<number, string> = { 0: 'CONFIG DATA', 1: 'MAX/MIN PRICES' }
const VEND_SUB: Record<number, string> = {
  0: 'REQUEST', 1: 'CANCEL', 2: 'SUCCESS', 3: 'FAILURE', 4: 'SESSION COMPLETE', 5: 'CASH SALE', 6: 'NEGATIVE REQUEST',
}
const READER_SUB: Record<number, string> = { 0: 'DISABLE', 1: 'ENABLE', 2: 'CANCEL', 3: 'DATA ENTRY RESPONSE' }
const EXPANSION_SUB: Record<number, string> = {
  0: 'REQUEST ID', 1: 'READ USER FILE', 2: 'WRITE USER FILE', 3: 'WRITE TIME/DATE', 4: 'OPTIONAL FEATURE ENABLED', 0xff: 'DIAGNOSTICS',
}

/** What a cashless device answers (first data byte of its reply). */
const CASHLESS_REPLIES: Record<number, string> = {
  0x00: 'JUST RESET',
  0x01: 'READER CONFIG DATA',
  0x02: 'DISPLAY REQUEST',
  0x03: 'BEGIN SESSION',
  0x04: 'SESSION CANCEL REQUEST',
  0x05: 'VEND APPROVED',
  0x06: 'VEND DENIED',
  0x07: 'END SESSION',
  0x08: 'CANCELLED',
  0x09: 'PERIPHERAL ID',
  0x0a: 'MALFUNCTION / ERROR',
  0x0b: 'CMD OUT OF SEQUENCE',
  0x0d: 'REVALUE APPROVED',
  0x0e: 'REVALUE DENIED',
  0x0f: 'REVALUE LIMIT AMOUNT',
  0x11: 'TIME/DATE REQUEST',
  0xff: 'DIAGNOSTIC RESPONSE',
}

// ── Annotation ───────────────────────────────────────────────────────────────

export type ChecksumState = 'ok' | 'bad' | null

export interface AnnotatedEntry {
  entry: TraceEntry
  /** Decoded name, e.g. "POLL", "VEND REQUEST", "BEGIN SESSION", "ACK". Empty when unknown. */
  title: string
  /** Who the VMC addressed ("Cashless #1"); null for replies and unknown words. */
  device: string | null
  /** Payload facts worth reading at a glance ("price 120 · item 12"). Raw MDB units. */
  detail: string | null
  /** Did the block's checksum add up? null when it cannot be told. */
  checksum: ChecksumState
  /** A VMC POLL, whoever it is for: the constant background chatter. */
  poll: boolean
  /** The single-word ACK. */
  ack: boolean
  /** RX only: true if addressed to this device, false if to another, null if unknown. */
  ours: boolean | null
}

function hex2(n: number): string {
  return n.toString(16).toUpperCase().padStart(2, '0')
}

function u16(hi: number | undefined, lo: number | undefined): number | null {
  if (hi === undefined || lo === undefined) return null
  return ((hi & 0xff) << 8) | (lo & 0xff)
}

/**
 * Does the block starting at words[0] add up? The checksum is the low 8 bits
 * of the sum of every preceding word (address byte included) and is itself a
 * data word. The frame may carry more than one block (another peripheral's
 * reply often follows the VMC command within the same inter-byte window), so
 * this looks for the first position where the running sum matches.
 */
function vmcChecksum(words: number[]): ChecksumState {
  if (words.length < 2) return null
  let sum = words[0]! & 0xff
  for (let k = 1; k < words.length; k++) {
    const w = words[k]!
    if (!(w & MODE_BIT) && (sum & 0xff) === (w & 0xff)) return 'ok'
    sum += w & 0xff
  }
  return 'bad'
}

/** A reply's last word is its checksum (mode bit set), covering the data words before it. */
function replyChecksum(words: number[]): ChecksumState {
  if (words.length < 2) return null
  let sum = 0
  for (let k = 0; k < words.length - 1; k++) sum += words[k]! & 0xff
  const chk = words[words.length - 1]!
  return (chk & MODE_BIT) && (sum & 0xff) === (chk & 0xff) ? 'ok' : 'bad'
}

interface Decoded { title: string; detail: string | null }

function decodeCashlessCommand(cmd: number, words: number[]): Decoded {
  const sub = words[1] !== undefined && !(words[1] & MODE_BIT) ? words[1] & 0xff : null
  const b = (i: number) => (words[i] !== undefined ? words[i]! & 0xff : undefined)

  switch (cmd) {
    case 1: { // SETUP
      if (sub === 0) return { title: 'SETUP · CONFIG DATA', detail: b(2) !== undefined ? `VMC level ${b(2)}` : null }
      if (sub === 1) {
        const max = u16(b(2), b(3)); const min = u16(b(4), b(5))
        return { title: 'SETUP · MAX/MIN PRICES', detail: max !== null && min !== null ? `max ${max} · min ${min}` : null }
      }
      return { title: sub === null ? 'SETUP' : `SETUP · 0x${hex2(sub)}`, detail: null }
    }
    case 3: { // VEND
      const name = sub === null ? 'VEND' : `VEND · ${VEND_SUB[sub] ?? `0x${hex2(sub)}`}`
      if (sub === 0 || sub === 5 || sub === 6) { // request / cash sale / negative request
        const price = u16(b(2), b(3)); const item = u16(b(4), b(5))
        const parts = [price !== null ? `price ${price}` : null, item !== null ? `item ${item}` : null].filter(Boolean)
        return { title: name, detail: parts.length ? parts.join(' · ') : null }
      }
      if (sub === 2) { const item = u16(b(2), b(3)); return { title: name, detail: item !== null ? `item ${item}` : null } }
      return { title: name, detail: null }
    }
    case 4: // READER
      return { title: sub === null ? 'READER' : `READER · ${READER_SUB[sub] ?? `0x${hex2(sub)}`}`, detail: null }
    case 7: // EXPANSION
      return { title: sub === null ? 'EXPANSION' : `EXPANSION · ${EXPANSION_SUB[sub] ?? `0x${hex2(sub)}`}`, detail: null }
    default:
      return { title: CASHLESS_COMMANDS[cmd] ?? `CMD ${cmd}`, detail: null }
  }
}

function decodeReply(words: number[]): Decoded {
  const data = words.slice(0, -1).map((w) => w & 0xff)   // without the checksum word
  const code = data[0]
  if (code === undefined) {
    // A lone word is an ACK only when it is exactly the mode bit + 0x00.
    return { title: words[0] === MODE_BIT ? 'ACK' : `CHK 0x${hex2((words[0] ?? 0) & 0xff)}`, detail: null }
  }

  const title = CASHLESS_REPLIES[code] ?? `REPLY 0x${hex2(code)}`
  switch (code) {
    case 0x01: { // reader config: level, country(2), scale, decimals, max response, options
      const [, level, , , scale, dec] = data
      return { title, detail: level !== undefined && scale !== undefined && dec !== undefined ? `level ${level} · scale ${scale} · ${dec} decimals` : null }
    }
    case 0x03: { const funds = u16(data[1], data[2]); return { title, detail: funds !== null ? `funds ${funds}` : null } }
    case 0x05: { const amount = u16(data[1], data[2]); return { title, detail: amount !== null ? `amount ${amount}` : null } }
    case 0x09: { // peripheral ID: 3 ASCII manufacturer bytes
      const mfr = data.slice(1, 4)
      return { title, detail: mfr.length === 3 && mfr.every((c) => c >= 0x20 && c < 0x7f) ? `mfr ${String.fromCharCode(...mfr)}` : null }
    }
    case 0x0a: return { title, detail: data[1] !== undefined ? `error 0x${hex2(data[1])}` : null }
    default: return { title, detail: null }
  }
}

function decodeVmcCommand(address: number, cmd: number, words: number[]): Decoded {
  if (CASHLESS_ADDRESSES.has(address)) return decodeCashlessCommand(cmd, words)
  if (address === 0x08) return { title: CHANGER_COMMANDS[cmd] ?? `CMD ${cmd}`, detail: null }
  if (address === 0x30) return { title: BILL_COMMANDS[cmd] ?? `CMD ${cmd}`, detail: null }
  return { title: `CMD ${cmd}`, detail: null }
}

/**
 * Annotate entries with their MDB meaning. `ourAddress` is the device's own
 * MDB address byte (0x10 or 0x60) when known, used to tell its traffic from
 * the rest of the bus.
 */
export function annotate(entries: TraceEntry[], ourAddress: number | null = null): AnnotatedEntry[] {
  return entries.map((entry): AnnotatedEntry => {
    const base = { entry, title: '', device: null, detail: null, checksum: null as ChecksumState, poll: false, ack: false, ours: null as boolean | null }
    if (entry.kind === 'gap') return base

    const { words } = entry
    if (entry.dir === 'tx') {
      const decoded = decodeReply(words)
      return { ...base, ...decoded, ack: words.length === 1 && words[0] === MODE_BIT, checksum: replyChecksum(words), ours: true }
    }

    // RX: a block from the VMC opens with an address word (mode bit set).
    const first = words[0]!
    if (!(first & MODE_BIT)) return base                               // a continuation or another peripheral's reply
    if (words.length === 1 && first === MODE_BIT) return { ...base, title: 'ACK', ack: true } // the VMC acknowledging a reply
    if (words.length === 1 && (first & 0xff) === 0xff) return { ...base, title: 'NAK' }
    if (words.length === 1 && (first & 0xff) === 0xaa) return { ...base, title: 'RET' }

    const address = first & 0xf8
    const cmd = first & 0x07
    const { title, detail } = decodeVmcCommand(address, cmd, words)
    const isCashless = CASHLESS_ADDRESSES.has(address)
    return {
      ...base,
      title,
      detail,
      device: DEVICE_NAMES[address] ?? `Device 0x${hex2(address)}`,
      checksum: vmcChecksum(words),
      // POLL is command 2 on a cashless device, 3 on a changer or bill validator.
      poll: (isCashless && cmd === 2) || ((address === 0x08 || address === 0x30) && cmd === 3),
      ours: ourAddress === null ? null : address === ourAddress,
    }
  })
}

// ── Filtering ────────────────────────────────────────────────────────────────

export interface TraceFilters {
  /** Hide VMC polls (any device) and our empty ACK to each of them. */
  hidePolls: boolean
  /** Hide commands the VMC addressed to other peripherals. */
  onlyOurs: boolean
}

export function filterAnnotated(list: AnnotatedEntry[], filters: TraceFilters): AnnotatedEntry[] {
  // An ACK is only noise when it answers a poll: the ACK to a RESET or a
  // VEND SUCCESS is part of the conversation being debugged.
  let lastRxWasPoll = false

  return list.filter((a) => {
    if (a.entry.kind === 'gap') return true            // never hide that data was lost

    if (a.entry.dir === 'rx') {
      lastRxWasPoll = a.poll
      if (filters.hidePolls && a.poll) return false
      if (filters.onlyOurs && a.ours === false) return false
      return true
    }

    return !(filters.hidePolls && a.ack && lastRxWasPoll)
  })
}

// ── Formatting ───────────────────────────────────────────────────────────────

/** HH:mm:ss.SSS, local time (or UTC, for deterministic tests). */
export function formatClock(ms: number, utc = false): string {
  const d = new Date(ms)
  const p = (n: number, w = 2) => String(n).padStart(w, '0')
  return utc
    ? `${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}.${p(d.getUTCMilliseconds(), 3)}`
    : `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`
}

/** "112 012": space-separated 3-digit words, as the console shows them. */
export function formatWords(words: number[]): string {
  return words.map((w) => w.toString(16).toUpperCase().padStart(3, '0')).join(' ')
}

/** Plain-text export of what the console shows (clipboard / .log download). */
export function toLogText(list: AnnotatedEntry[], utc = false): string {
  return list
    .map((a) => {
      const time = formatClock(a.entry.time, utc)
      if (a.entry.kind === 'gap') return `${time}  !!  ${a.entry.dropped} words lost on the device`
      const arrow = a.entry.dir === 'tx' ? 'TX' : 'RX'
      const chk = a.checksum === 'ok' ? 'chk ok' : a.checksum === 'bad' ? 'CHK BAD' : ''
      const what = [a.device, a.title, a.detail].filter(Boolean).join(' · ')
      return [time, arrow, formatWords(a.entry.words).padEnd(24), what, chk].filter((s) => s !== '').join('  ').trimEnd()
    })
    .join('\n')
}

/** The device's MDB address byte from the diagnostics string ("0x10"); null when absent or unusable. */
export function parseMdbAddress(addr: string | null | undefined): number | null {
  if (!addr) return null
  const n = parseInt(addr, 16)
  return Number.isInteger(n) && n >= 0 && n <= 0xff ? n & 0xf8 : null
}

/** Most entries kept in memory by the console; older ones scroll off. */
export const MAX_TRACE_ENTRIES = 3000
