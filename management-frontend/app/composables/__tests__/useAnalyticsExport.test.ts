import { describe, it, expect } from 'vitest'
import { rowsToCsv } from '../useAnalyticsExport'

describe('rowsToCsv', () => {
  it('emits UTF-8 BOM and ; delimiter', () => {
    const csv = rowsToCsv(
      [{ name: 'a', revenue: 1.5 }, { name: 'b', revenue: 2.7 }],
      ['name', 'revenue']
    )
    expect(csv.startsWith('﻿')).toBe(true)
    const lines = csv.replace('﻿', '').split('\n')
    expect(lines[0]).toBe('name;revenue')
    expect(lines[1]).toBe('a;1,5')         // German decimal
    expect(lines[2]).toBe('b;2,7')
  })

  it('escapes values containing ; or " or newline', () => {
    const csv = rowsToCsv(
      [{ name: 'a;b', note: 'has "quote"' }, { name: 'multi\nline', note: 'ok' }],
      ['name', 'note']
    )
    expect(csv).toContain('"a;b"')
    expect(csv).toContain('"has ""quote"""')
    expect(csv).toContain('"multi\nline"')
  })
})
