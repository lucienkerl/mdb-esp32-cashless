import { describe, it, expect } from 'vitest'
import {
  findInternalItemNumberConflict,
  findShadowingTray,
  parseInternalItemNumber,
} from '../trayInternalNumber'

describe('parseInternalItemNumber', () => {
  it('treats an empty field as "no mapping"', () => {
    expect(parseInternalItemNumber('')).toBeNull()
    expect(parseInternalItemNumber('   ')).toBeNull()
    expect(parseInternalItemNumber(null)).toBeNull()
    expect(parseInternalItemNumber(undefined)).toBeNull()
  })

  it('accepts whole numbers, typed or already cast by v-model', () => {
    expect(parseInternalItemNumber('3')).toBe(3)
    expect(parseInternalItemNumber(' 12 ')).toBe(12)
    expect(parseInternalItemNumber(0)).toBe(0)
    expect(parseInternalItemNumber(65534)).toBe(65534)
  })

  it('rejects negatives, fractions, text and numbers beyond the MDB range', () => {
    expect(parseInternalItemNumber('-1')).toBe('invalid')
    expect(parseInternalItemNumber('1.5')).toBe('invalid')
    expect(parseInternalItemNumber('abc')).toBe('invalid')
    expect(parseInternalItemNumber('65535')).toBe('invalid')
  })
})

const trays = [
  { id: 'a', item_number: 10, internal_item_number: 1 },
  { id: 'b', item_number: 11, internal_item_number: 2 },
  { id: 'c', item_number: 1, internal_item_number: null },
  { id: 'd', item_number: 20, internal_item_number: null },
]

describe('findInternalItemNumberConflict', () => {
  it('finds another tray that already uses the number', () => {
    expect(findInternalItemNumberConflict(trays, 'b', 1)?.id).toBe('a')
  })

  it('does not report the tray against itself', () => {
    expect(findInternalItemNumberConflict(trays, 'a', 1)).toBeUndefined()
  })

  it('checks every tray when the tray does not exist yet', () => {
    expect(findInternalItemNumberConflict(trays, null, 2)?.id).toBe('b')
    expect(findInternalItemNumberConflict(trays, null, 3)).toBeUndefined()
  })
})

describe('findShadowingTray', () => {
  it('finds the mapped tray that takes the sales reported as this slot number', () => {
    expect(findShadowingTray(trays, trays[2]!)?.id).toBe('a')
  })

  it('is empty when nothing is mapped to this slot number', () => {
    expect(findShadowingTray(trays, trays[3]!)).toBeUndefined()
  })

  it('is empty for a tray that has its own mapping', () => {
    const own = { id: 'e', item_number: 2, internal_item_number: 5 }
    expect(findShadowingTray([...trays, own], own)).toBeUndefined()
  })
})
