import { describe, expect, it } from 'vitest'
import {
  countInputChanges,
  formatClockSeconds,
  ioTestStatus,
  isLive,
  isWroomBoard,
  newestIoState,
  oneWireFamily,
  remainingSeconds,
  type IoState,
} from '../ioTest'

const T0 = Date.parse('2026-11-04T12:00:00Z')

function snap(over: Partial<IoState> = {}, at = T0): IoState {
  return { active: true, left: 120, in: [1, 1, 1], relay: [0, 0], updated_at: new Date(at).toISOString(), ...over }
}

describe('isWroomBoard', () => {
  it('only the wroom-1u board', () => {
    expect(isWroomBoard({ board: 'wroom-1u' })).toBe(true)
    expect(isWroomBoard({ board: 'original' })).toBe(false)
    expect(isWroomBoard({ state: 'ENABLED' })).toBe(false) // firmware without the field
    expect(isWroomBoard(null)).toBe(false)
  })
})

describe('isLive / remainingSeconds', () => {
  it('counts down from the last snapshot', () => {
    expect(remainingSeconds(snap(), T0 + 30_500)).toBe(90)
    expect(remainingSeconds(snap(), T0 + 200_000)).toBe(0)
  })

  it('a stale or ended snapshot is not live', () => {
    expect(isLive(snap(), T0 + 5_000)).toBe(true)
    expect(isLive(snap(), T0 + 13_000)).toBe(false)
    expect(isLive(snap({ active: false }), T0)).toBe(false)
    expect(remainingSeconds(snap({ active: false }), T0)).toBe(0)
    expect(isLive(null, T0)).toBe(false)
  })
})

describe('ioTestStatus', () => {
  it('live while fresh snapshots arrive', () => {
    expect(ioTestStatus(snap(), T0 + 1_000, null)).toBe('live')
  })

  it('waiting right after a request until a newer snapshot arrives', () => {
    const old = snap({ active: false }, T0 - 60_000)
    expect(ioTestStatus(old, T0 + 2_000, T0)).toBe('waiting')
    expect(ioTestStatus(null, T0 + 2_000, T0)).toBe('waiting')
    // gave up waiting
    expect(ioTestStatus(old, T0 + 20_000, T0)).toBe('idle')
  })

  it('idle once the device answered with an ended test', () => {
    expect(ioTestStatus(snap({ active: false }, T0 + 1_000), T0 + 2_000, T0)).toBe('idle')
  })
})

describe('newestIoState', () => {
  it('keeps the snapshot with the later updated_at', () => {
    const older = snap({ left: 50 }, T0)
    const newer = snap({ left: 45 }, T0 + 5_000)
    expect(newestIoState(older, newer)).toBe(newer)
    expect(newestIoState(newer, older)).toBe(newer)
    expect(newestIoState(null, older)).toBe(older)
    expect(newestIoState(older, null)).toBe(older)
    expect(newestIoState(null, null)).toBeNull()
  })
})

describe('countInputChanges', () => {
  it('counts one change per input that flipped', () => {
    expect(countInputChanges([1, 1, 0], [0, 1, 1], [0, 2, 0])).toEqual([1, 2, 1])
    expect(countInputChanges(undefined, [0, 1, 1], [0, 0, 0])).toEqual([0, 0, 0])
  })
})

describe('oneWireFamily / formatClockSeconds', () => {
  it('reads the family from the low byte', () => {
    expect(oneWireFamily('3C01F0956E4AFF28')).toBe('DS18B20')
    expect(oneWireFamily('00000000000000AB')).toBeNull()
  })

  it('formats m:ss', () => {
    expect(formatClockSeconds(125)).toBe('2:05')
    expect(formatClockSeconds(0)).toBe('0:00')
  })
})
