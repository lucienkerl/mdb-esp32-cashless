import { describe, it, expect } from 'vitest'
import {
  annotate,
  filterAnnotated,
  formatClock,
  formatWords,
  parseMdbAddress,
  parseWords,
  rowToEntries,
  toLogText,
  type MdbTraceRow,
  type TraceEntry,
  type TraceFrameEntry,
} from '../mdbTrace'

const T0 = Date.parse('2026-10-09T17:00:00.000Z')

function frame(dir: 'rx' | 'tx', words: number[], i = 0): TraceFrameEntry {
  return { kind: 'frame', id: `t:${i}`, time: T0 + i, dir, words }
}
function one(dir: 'rx' | 'tx', words: number[], ours: number | null = 0x10) {
  return annotate([frame(dir, words)], ours)[0]!
}

describe('parseWords', () => {
  it('splits fixed-width 3-digit hex into 9-bit words', () => {
    expect(parseWords('112012')).toEqual([0x112, 0x012])
    expect(parseWords('1FF')).toEqual([0x1ff])
  })

  it('rejects anything that is not whole valid words', () => {
    expect(parseWords('')).toEqual([])
    expect(parseWords('11')).toEqual([])
    expect(parseWords('11g')).toEqual([])
    expect(parseWords('200')).toEqual([])    // above 9 bits
    expect(parseWords('112 012')).toEqual([])
  })
})

describe('rowToEntries', () => {
  const row: MdbTraceRow = {
    id: 7,
    created_at: '2026-10-09T17:00:00.000Z',
    embedded_id: 'dev-1',
    dropped: 0,
    frames: [[30, 'r', '112012'], [20, 't', '000100']],
  }

  it('anchors each frame at the batch arrival minus its age, in order', () => {
    const entries = rowToEntries(row)
    expect(entries).toHaveLength(2)
    expect(entries[0]).toMatchObject({ kind: 'frame', id: '7:0', time: T0 - 30, dir: 'rx', words: [0x112, 0x012] })
    expect(entries[1]).toMatchObject({ kind: 'frame', id: '7:1', time: T0 - 20, dir: 'tx', words: [0x000, 0x100] })
  })

  it('puts a gap marker in front of the batch when the device lost words', () => {
    const entries = rowToEntries({ ...row, dropped: 12 })
    expect(entries.map((e) => e.kind)).toEqual(['gap', 'frame', 'frame'])
    expect(entries[0]).toMatchObject({ id: '7:gap', dropped: 12, time: T0 - 30 })
  })

  it('skips frames it cannot read instead of failing the whole batch', () => {
    const bad = { ...row, frames: [[1, 'r', 'zzz'], [2, 'r', '112'], 'nope' as never] }
    expect(rowToEntries(bad).map((e) => e.id)).toEqual(['7:1'])
  })

  it('returns nothing for an unreadable timestamp', () => {
    expect(rowToEntries({ ...row, created_at: 'yesterday' })).toEqual([])
  })
})

describe('annotate — commands from the VMC', () => {
  it('names a POLL to our device and verifies its checksum', () => {
    const a = one('rx', [0x112, 0x012])
    expect(a).toMatchObject({ title: 'POLL', device: 'Cashless #1', checksum: 'ok', poll: true, ours: true })
  })

  it('flags a checksum that does not add up', () => {
    expect(one('rx', [0x112, 0x013]).checksum).toBe('bad')
    expect(one('rx', [0x112]).checksum).toBeNull()      // truncated: nothing to compare
  })

  it('decodes SETUP / CONFIG DATA with the VMC level', () => {
    const a = one('rx', [0x111, 0x000, 0x003, 0x010, 0x002, 0x000, 0x026])
    expect(a).toMatchObject({ title: 'SETUP · CONFIG DATA', detail: 'VMC level 3', checksum: 'ok' })
  })

  it('decodes VEND / REQUEST with price and item', () => {
    const a = one('rx', [0x113, 0x000, 0x000, 0x078, 0x000, 0x00c, 0x097])
    expect(a).toMatchObject({ title: 'VEND · REQUEST', detail: 'price 120 · item 12', checksum: 'ok' })
  })

  it('decodes VEND / SUCCESS, READER and EXPANSION sub-commands', () => {
    expect(one('rx', [0x113, 0x002, 0x000, 0x00c, 0x12c])).toMatchObject({ title: 'VEND · SUCCESS', detail: 'item 12' })
    expect(one('rx', [0x114, 0x001, 0x015])).toMatchObject({ title: 'READER · ENABLE', checksum: 'ok' })
    expect(one('rx', [0x117, 0x000, 0x017])).toMatchObject({ title: 'EXPANSION · REQUEST ID' })
  })

  it('tells traffic for other peripherals apart and knows their polls', () => {
    const changer = one('rx', [0x10b, 0x00b])
    expect(changer).toMatchObject({ title: 'POLL', device: 'Changer', poll: true, ours: false })
    expect(one('rx', [0x112, 0x012], 0x60).ours).toBe(false)      // we are configured as cashless #2
    expect(one('rx', [0x112, 0x012], null).ours).toBeNull()       // own address unknown
  })

  it('handles a block followed by another peripheral\'s reply in the same frame', () => {
    expect(one('rx', [0x112, 0x012, 0x000, 0x100]).checksum).toBe('ok')
  })

  it('recognises the single-word ACK / NAK / RET and leaves continuations alone', () => {
    expect(one('rx', [0x100])).toMatchObject({ title: 'ACK', ack: true })
    expect(one('rx', [0x1ff]).title).toBe('NAK')
    expect(one('rx', [0x1aa]).title).toBe('RET')
    expect(one('rx', [0x012, 0x034])).toMatchObject({ title: '', device: null, ours: null })
  })
})

describe('annotate — replies from this device', () => {
  it('JUST RESET', () => {
    expect(one('tx', [0x000, 0x100])).toMatchObject({ title: 'JUST RESET', checksum: 'ok', ours: true })
  })

  it('ACK is a lone mode-bit word, with nothing to checksum', () => {
    expect(one('tx', [0x100])).toMatchObject({ title: 'ACK', ack: true, checksum: null })
  })

  it('BEGIN SESSION shows the funds', () => {
    expect(one('tx', [0x003, 0x000, 0x078, 0x17b])).toMatchObject({ title: 'BEGIN SESSION', detail: 'funds 120', checksum: 'ok' })
  })

  it('VEND APPROVED shows the amount, VEND DENIED has no detail', () => {
    expect(one('tx', [0x005, 0x000, 0x078, 0x17d])).toMatchObject({ title: 'VEND APPROVED', detail: 'amount 120' })
    expect(one('tx', [0x006, 0x106])).toMatchObject({ title: 'VEND DENIED', detail: null, checksum: 'ok' })
  })

  it('READER CONFIG DATA shows level, scale and decimals', () => {
    const a = one('tx', [0x001, 0x001, 0x009, 0x078, 0x001, 0x002, 0x003, 0x009, 0x192])
    expect(a).toMatchObject({ title: 'READER CONFIG DATA', detail: 'level 1 · scale 1 · 2 decimals', checksum: 'ok' })
  })

  it('PERIPHERAL ID shows the manufacturer code', () => {
    expect(one('tx', [0x009, 0x056, 0x04d, 0x046, 0x1f2])).toMatchObject({ title: 'PERIPHERAL ID', detail: 'mfr VMF', checksum: 'ok' })
  })

  it('flags a reply whose checksum word is wrong', () => {
    expect(one('tx', [0x000, 0x101]).checksum).toBe('bad')
  })

  it('does not call a stray lone word an ACK', () => {
    const a = one('tx', [0x1a5])
    expect(a.ack).toBe(false)
    expect(a.title).toBe('CHK 0xA5')
  })
})

describe('filterAnnotated', () => {
  const gap: TraceEntry = { kind: 'gap', id: 'g', time: T0, dropped: 5 }
  const list = annotate([
    frame('rx', [0x112, 0x012], 1),                       // our poll
    frame('tx', [0x100], 2),                              // ACK to that poll
    frame('rx', [0x10b, 0x00b], 3),                       // changer poll
    frame('rx', [0x113, 0x001, 0x114], 4),                // our VEND CANCEL
    frame('tx', [0x100], 5),                              // ACK to a real command
    frame('rx', [0x112, 0x012], 6),
    frame('tx', [0x003, 0x000, 0x078, 0x17b], 7),         // BEGIN SESSION (answer to a poll, but not empty)
    gap,
  ], 0x10)

  const ids = (l: ReturnType<typeof annotate>) => l.map((a) => a.entry.id)

  it('shows everything by default', () => {
    expect(filterAnnotated(list, { hidePolls: false, onlyOurs: false })).toHaveLength(list.length)
  })

  it('hides polls and the ACK to a poll, but keeps the ACK to a real command', () => {
    const kept = filterAnnotated(list, { hidePolls: true, onlyOurs: false })
    expect(ids(kept)).toEqual(['t:4', 't:5', 't:7', 'g'])
  })

  it('hides commands for other peripherals only', () => {
    const kept = filterAnnotated(list, { hidePolls: false, onlyOurs: true })
    expect(ids(kept)).not.toContain('t:3')
    expect(kept).toHaveLength(list.length - 1)
  })

  it('never hides the marker that words were lost', () => {
    expect(ids(filterAnnotated(list, { hidePolls: true, onlyOurs: true }))).toContain('g')
  })
})

describe('formatting', () => {
  it('formats words as padded upper-case hex', () => {
    expect(formatWords([0x112, 0x12, 0x0])).toBe('112 012 000')
  })

  it('formats the clock down to milliseconds', () => {
    expect(formatClock(Date.parse('2026-10-09T17:04:05.006Z'), true)).toBe('17:04:05.006')
  })

  it('exports a readable log', () => {
    const text = toLogText(annotate([
      frame('rx', [0x112, 0x012], 0),
      frame('tx', [0x000, 0x100], 1),
      { kind: 'gap', id: 'g', time: T0 + 2, dropped: 3 },
      frame('rx', [0x112, 0x013], 3),
    ], 0x10), true)
    // Words are padded to a fixed column so the decoded text lines up.
    const col = (w: string) => w.padEnd(24)
    expect(text.split('\n')).toEqual([
      `17:00:00.000  RX  ${col('112 012')}  Cashless #1 · POLL  chk ok`,
      `17:00:00.001  TX  ${col('000 100')}  JUST RESET  chk ok`,
      '17:00:00.002  !!  3 words lost on the device',
      `17:00:00.003  RX  ${col('112 013')}  Cashless #1 · POLL  CHK BAD`,
    ])
  })
})

describe('parseMdbAddress', () => {
  it('reads the diagnostics string and keeps only the address bits', () => {
    expect(parseMdbAddress('0x10')).toBe(0x10)
    expect(parseMdbAddress('0x60')).toBe(0x60)
    expect(parseMdbAddress('0x13')).toBe(0x10)
  })

  it('returns null for anything unusable', () => {
    expect(parseMdbAddress(null)).toBeNull()
    expect(parseMdbAddress('')).toBeNull()
    expect(parseMdbAddress('nope')).toBeNull()
    expect(parseMdbAddress('0x1FF')).toBeNull()
  })
})
