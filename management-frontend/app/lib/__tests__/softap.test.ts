import { describe, it, expect } from 'vitest'
import { computeSoftApSsid, formatWifiQrPayload } from '../softap'

describe('computeSoftApSsid', () => {
  it('formats last 3 bytes uppercase from a colon-separated MAC', () => {
    expect(computeSoftApSsid('f4:12:fa:a1:b2:c3')).toBe('VMflow-A1B2C3')
  })
  it('handles dash-separated MACs', () => {
    expect(computeSoftApSsid('F4-12-FA-A1-B2-C3')).toBe('VMflow-A1B2C3')
  })
  it('handles bare-hex MACs (no separators)', () => {
    expect(computeSoftApSsid('f412faa1b2c3')).toBe('VMflow-A1B2C3')
  })
  it('falls back to a placeholder when MAC is null', () => {
    expect(computeSoftApSsid(null)).toBe('VMflow-?')
  })
  it('falls back when MAC is malformed', () => {
    expect(computeSoftApSsid('not-a-mac')).toBe('VMflow-?')
    expect(computeSoftApSsid('aa:bb:cc')).toBe('VMflow-?')  // too short
  })
})

describe('formatWifiQrPayload', () => {
  it('produces a standard WIFI: URI', () => {
    expect(formatWifiQrPayload('VMflow-A1B2C3', 'AbCd2EfG3HjK'))
      .toBe('WIFI:T:WPA;S:VMflow-A1B2C3;P:AbCd2EfG3HjK;;')
  })
  it('escapes special characters in the password per WPA QR spec', () => {
    expect(formatWifiQrPayload('VMflow-X', 'a;b\\c"d:e,f'))
      .toBe('WIFI:T:WPA;S:VMflow-X;P:a\\;b\\\\c\\"d\\:e\\,f;;')
  })
})
