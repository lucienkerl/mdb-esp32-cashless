import { describe, it, expect } from 'vitest'
import { extractCardSerials, keepsCardSerials } from '../useCardAccounts'

// The reader resolves an account by finding its card serial inside the
// account name, so these two helpers are what stands between an operator's
// rename and a card that silently stops working.

describe('extractCardSerials', () => {
  it('finds the serial in an auto-created account name', () => {
    expect(extractCardSerials('04A1B2C3')).toEqual(['04A1B2C3'])
  })

  it('finds a serial embedded in a human name', () => {
    expect(extractCardSerials('Jane Doe (04A1B2C3)')).toEqual(['04A1B2C3'])
  })

  it('is case-insensitive about the hex', () => {
    expect(extractCardSerials('jane 04a1b2c3')).toEqual(['04A1B2C3'])
  })

  it('ignores short hex-looking runs like a house number', () => {
    expect(extractCardSerials('Jane Doe 42')).toEqual([])
  })

  it('finds both serials when a person carries two cards', () => {
    expect(extractCardSerials('Jane 04A1B2C3 / 0BADC0DE')).toEqual(['04A1B2C3', '0BADC0DE'])
  })
})

describe('keepsCardSerials', () => {
  it('accepts adding a human name around the serial', () => {
    expect(keepsCardSerials('04A1B2C3', 'Jane Doe (04A1B2C3)')).toBe(true)
  })

  it('accepts a case change of the serial', () => {
    expect(keepsCardSerials('04A1B2C3', 'Jane (04a1b2c3)')).toBe(true)
  })

  it('rejects a rename that drops the serial', () => {
    expect(keepsCardSerials('04A1B2C3', 'Jane Doe')).toBe(false)
  })

  it('rejects a rename that drops one of two serials', () => {
    expect(keepsCardSerials('Jane 04A1B2C3 0BADC0DE', 'Jane 04A1B2C3')).toBe(false)
  })

  it('accepts any rename when the old name had no serial at all', () => {
    expect(keepsCardSerials('Kitchen float', 'Office float')).toBe(true)
  })
})
