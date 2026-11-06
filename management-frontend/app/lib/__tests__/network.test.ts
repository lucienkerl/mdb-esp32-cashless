import { describe, expect, it } from 'vitest'
import { deviceNetwork, signalLevel, signalQuality, signalTone } from '../network'

describe('signalLevel', () => {
  it.each([
    [-40, 4], [-55, 4], [-56, 3], [-67, 3], [-68, 2], [-75, 2], [-76, 1], [-85, 1], [-86, 0], [-100, 0],
  ])('wifi %i dBm → %i', (rssi, level) => {
    expect(signalLevel('wifi', rssi)).toBe(level)
  })

  it.each([
    [-50, 4], [-65, 4], [-66, 3], [-80, 3], [-81, 2], [-95, 2], [-96, 1], [-105, 1], [-106, 0],
  ])('cellular %i dBm → %i', (rssi, level) => {
    expect(signalLevel('cellular', rssi)).toBe(level)
  })

  it('has no level without a reading', () => {
    expect(signalLevel('wifi', null)).toBeNull()
    expect(signalLevel('wifi', undefined)).toBeNull()
    expect(signalLevel('wifi', 0)).toBeNull()
    expect(signalLevel('cellular', Number.NaN)).toBeNull()
  })
})

describe('signalQuality / signalTone', () => {
  it('maps levels to words and tones', () => {
    expect([0, 1, 2, 3, 4].map(signalQuality)).toEqual(['none', 'weak', 'fair', 'good', 'excellent'])
    expect([0, 1, 2, 3, 4].map(signalTone)).toEqual(['bad', 'weak', 'ok', 'ok', 'ok'])
    expect(signalQuality(null)).toBeNull()
    expect(signalTone(null)).toBeNull()
  })
})

describe('deviceNetwork', () => {
  it('returns null without uplink data', () => {
    expect(deviceNetwork(null)).toBeNull()
    expect(deviceNetwork({ state: 'ENABLED' })).toBeNull()
    expect(deviceNetwork({ network: { uplink: 'none' } })).toBeNull()
  })

  it('reads a wifi network block', () => {
    const n = deviceNetwork({
      network: { uplink: 'wifi', ssid: 'Büro-WLAN', rssi: -62, ip: '192.168.1.47', measured_at: '2026-11-06T12:00:00.000Z' },
    })
    expect(n).toEqual({
      kind: 'wifi',
      name: 'Büro-WLAN',
      rssi: -62,
      level: 3,
      quality: 'good',
      tone: 'ok',
      mode: null,
      ip: '192.168.1.47',
      measuredAt: new Date('2026-11-06T12:00:00.000Z'),
    })
  })

  it('reads a cellular network block', () => {
    const n = deviceNetwork({
      network: { uplink: 'cellular', op: 'Telekom.de', rssi: -78, mode: 'LTE-M', ip: '10.0.0.1', measured_at: '2026-11-06T12:00:00.000Z' },
    })!
    expect(n.kind).toBe('cellular')
    expect(n.name).toBe('Telekom.de')
    expect(n.mode).toBe('LTE-M')
    expect(n.level).toBe(3)
  })

  it('falls back to the legacy cellular block', () => {
    const n = deviceNetwork({ cellular: { uplink: 'cellular', op: 'Vodafone DE', rssi: -100, mode: 'NB-IoT' } })!
    expect(n.kind).toBe('cellular')
    expect(n.name).toBe('Vodafone DE')
    expect(n.tone).toBe('weak')
    expect(n.measuredAt).toBeNull()
  })

  it('prefers the network block over a stale cellular block', () => {
    const n = deviceNetwork({
      network: { uplink: 'wifi', ssid: 'Office', rssi: -90 },
      cellular: { uplink: 'cellular', op: 'Telekom.de', rssi: -70 },
    })!
    expect(n.kind).toBe('wifi')
    expect(n.tone).toBe('bad')
  })

  it('treats firmware placeholders as unknown', () => {
    const n = deviceNetwork({ network: { uplink: 'cellular', op: 'unknown', ip: '0.0.0.0', mode: '?', rssi: 0 } })!
    expect(n.name).toBeNull()
    expect(n.ip).toBeNull()
    expect(n.mode).toBeNull()
    expect(n.rssi).toBeNull()
    expect(n.level).toBeNull()
  })
})
