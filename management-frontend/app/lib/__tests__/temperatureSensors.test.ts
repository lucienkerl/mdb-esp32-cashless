import { describe, expect, it } from 'vitest'
import {
  cleanTempSettings,
  formatCelsius,
  isTempsStale,
  knownSensors,
  mergeReadings,
  parseTempSettings,
  readingsFromDiagnostics,
  readingsFromIoState,
  sensorLabel,
  shortProbeId,
  shownTemperatures,
  TEMPS_STALE_MS,
  upsertTempSetting,
} from '../temperatureSensors'

const T0 = Date.parse('2026-11-05T12:00:00Z')
const PROBE_A = '4200000025040628'
const PROBE_B = 'F2000000CA146228'

describe('parseTempSettings', () => {
  it('drops bad entries and duplicates, normalises ids and names', () => {
    expect(parseTempSettings([
      { id: 'NTC', name: '  PCB  ', show: true },
      { id: PROBE_A.toLowerCase(), name: 'Frigo', show: 'yes' },
      { id: PROBE_A, name: 'dup', show: true },
      { id: '', name: 'x' },
      null,
      'ntc',
    ])).toEqual([
      { id: 'ntc', name: 'PCB', show: true },
      { id: PROBE_A, name: 'Frigo', show: false },
    ])
  })

  it('returns [] for anything but an array', () => {
    expect(parseTempSettings(null)).toEqual([])
    expect(parseTempSettings({ id: 'ntc' })).toEqual([])
  })

  it('caps long names', () => {
    expect(parseTempSettings([{ id: 'ntc', name: 'x'.repeat(100), show: true }])[0]!.name).toHaveLength(40)
  })
})

describe('cleanTempSettings', () => {
  it('drops entries without a name that are not shown', () => {
    expect(cleanTempSettings([
      { id: 'ntc', name: '', show: false },
      { id: PROBE_A, name: ' ', show: true },
      { id: PROBE_B, name: 'Bac', show: false },
    ])).toEqual([
      { id: PROBE_A, name: '', show: true },
      { id: PROBE_B, name: 'Bac', show: false },
    ])
  })
})

describe('readingsFromDiagnostics', () => {
  it('reads the NTC and the probes that have a temperature', () => {
    expect(readingsFromDiagnostics({
      state: 'ENABLED',
      temps: { ntc: 41.3, ow: [{ id: PROBE_A, b: 1, t: 25.69 }, { id: PROBE_B, b: 2 }, { t: 3 }] },
    })).toEqual([
      { id: 'ntc', celsius: 41.3 },
      { id: PROBE_A, bus: 1, celsius: 25.69 },
    ])
  })

  it('is empty without a temps block (older firmware)', () => {
    expect(readingsFromDiagnostics({ state: 'ENABLED' })).toEqual([])
    expect(readingsFromDiagnostics(null)).toEqual([])
  })
})

describe('readingsFromIoState', () => {
  it('reads the NTC and both buses', () => {
    expect(readingsFromIoState({
      active: true, left: 10, in: [], relay: [], ntc: 40,
      ow: [[{ id: PROBE_A, t: 25.7 }], [{ id: PROBE_B, t: 25.5 }, { id: '0100000000000001' }]],
    })).toEqual([
      { id: 'ntc', celsius: 40 },
      { id: PROBE_A, bus: 1, celsius: 25.7 },
      { id: PROBE_B, bus: 2, celsius: 25.5 },
    ])
  })
})

describe('mergeReadings', () => {
  it('keeps the first list that has a sensor', () => {
    expect(mergeReadings(
      [{ id: 'ntc', celsius: 40 }],
      [{ id: 'ntc', celsius: 30 }, { id: PROBE_A, celsius: 5 }],
    )).toEqual([{ id: 'ntc', celsius: 40 }, { id: PROBE_A, celsius: 5 }])
  })
})

describe('knownSensors', () => {
  it('lists the NTC first, then saved sensors, then new probes', () => {
    const list = knownSensors(
      [{ id: PROBE_B, name: 'Bac', show: true }, { id: 'ntc', name: 'PCB', show: false }],
      [{ id: PROBE_A, celsius: 5 }, { id: 'ntc', celsius: 41 }],
    )
    expect(list.map(s => s.id)).toEqual(['ntc', PROBE_B, PROBE_A])
    expect(list[0]).toMatchObject({ name: 'PCB', show: false, reading: { celsius: 41 } })
    expect(list[1]).toMatchObject({ name: 'Bac', show: true, reading: null })
    expect(list[2]).toMatchObject({ name: '', show: false, reading: { celsius: 5 } })
  })
})

describe('upsertTempSetting', () => {
  it('adds a missing sensor and patches an existing one', () => {
    const added = upsertTempSetting([], PROBE_A, { show: true })
    expect(added).toEqual([{ id: PROBE_A, name: '', show: true }])
    expect(upsertTempSetting(added, PROBE_A, { name: 'Frigo' })).toEqual([{ id: PROBE_A, name: 'Frigo', show: true }])
  })
})

describe('labels', () => {
  it('uses the name, else PCB for the NTC, else the short ROM id', () => {
    expect(sensorLabel('ntc', 'Carte', 'PCB')).toBe('Carte')
    expect(sensorLabel('ntc', '', 'PCB')).toBe('PCB')
    expect(sensorLabel(PROBE_B, undefined, 'PCB')).toBe('#CA1462')
    expect(shortProbeId('weird')).toBe('weird')
  })

  it('formats °C', () => {
    expect(formatCelsius(41.26)).toBe('41.3 °C')
    expect(formatCelsius(null)).toBe('–')
  })
})

describe('shownTemperatures', () => {
  it('keeps only shown sensors, in saved order, with null when not reported', () => {
    expect(shownTemperatures(
      [
        { id: PROBE_A, name: 'Frigo', show: true },
        { id: 'ntc', name: '', show: true },
        { id: PROBE_B, name: 'Bac', show: false },
      ],
      [{ id: 'ntc', celsius: 41.5 }],
      'PCB',
    )).toEqual([
      { id: PROBE_A, label: 'Frigo', celsius: null },
      { id: 'ntc', label: 'PCB', celsius: 41.5 },
    ])
  })
})

describe('isTempsStale', () => {
  it('is stale without a timestamp or past the window', () => {
    expect(isTempsStale({}, T0)).toBe(true)
    expect(isTempsStale({ updated_at: new Date(T0 - 60_000).toISOString() }, T0)).toBe(false)
    expect(isTempsStale({ updated_at: new Date(T0 - TEMPS_STALE_MS - 1).toISOString() }, T0)).toBe(true)
  })
})
