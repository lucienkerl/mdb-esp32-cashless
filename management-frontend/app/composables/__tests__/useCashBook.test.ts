import { describe, it, expect } from 'vitest'
import {
  changeFloatAmount,
  floatBalanceForMachine,
  totalChangeFloat,
  type MachineChangeFloat,
} from '../useCashBook'

const rows: MachineChangeFloat[] = [
  { machine_id: 'm1', machine_name: 'A', cash_book_id: 'b1', float_balance: 45, last_change_at: '2026-08-01T10:00:00Z' },
  { machine_id: 'm2', machine_name: 'B', cash_book_id: 'b1', float_balance: 80, last_change_at: '2026-08-02T10:00:00Z' },
  { machine_id: 'm1', machine_name: 'A', cash_book_id: 'b2', float_balance: 20, last_change_at: '2026-08-03T10:00:00Z' },
]

describe('changeFloatAmount', () => {
  it('negates the amount when money goes into the machine', () => {
    expect(changeFloatAmount('into_machine', 50)).toBe(-50)
  })

  it('keeps the amount positive when money comes back to the box', () => {
    expect(changeFloatAmount('back_to_box', 50)).toBe(50)
  })

  it('ignores the sign of the input — the direction decides', () => {
    expect(changeFloatAmount('into_machine', -50)).toBe(-50)
    expect(changeFloatAmount('back_to_box', -50)).toBe(50)
  })

  it('maps zero to zero for both directions', () => {
    expect(changeFloatAmount('into_machine', 0)).toBe(0)
    expect(changeFloatAmount('back_to_box', 0)).toBe(0)
  })

  it('passes NaN through instead of turning it into a valid zero', () => {
    expect(changeFloatAmount('into_machine', NaN)).toBeNaN()
    expect(changeFloatAmount('back_to_box', NaN)).toBeNaN()
  })

  it('never returns negative zero, which would render as "-0,00 €"', () => {
    expect(Object.is(changeFloatAmount('into_machine', 0), -0)).toBe(false)
    expect(Object.is(changeFloatAmount('back_to_box', 0), -0)).toBe(false)
  })
})

describe('floatBalanceForMachine', () => {
  it('scopes to the given cash book, not the machine\'s total across every cash book', () => {
    // m1 has 45 in b1 and 20 in b2 — a caller scoped to b1 must see only 45,
    // not the 65 cross-book sum (that sum is exactly the bug: a machine that
    // moved cash books would show an inflated balance and suppress the
    // over-return warning in the book it actually sits in now).
    expect(floatBalanceForMachine(rows, 'm1', 'b1')).toBe(45)
    expect(floatBalanceForMachine(rows, 'm1', 'b2')).toBe(20)
  })

  it('returns the single balance for a machine in one cash book', () => {
    expect(floatBalanceForMachine(rows, 'm2', 'b1')).toBe(80)
  })

  it('returns zero for a machine with no float in that cash book', () => {
    expect(floatBalanceForMachine(rows, 'unknown', 'b1')).toBe(0)
    expect(floatBalanceForMachine(rows, 'm2', 'b2')).toBe(0)
  })

  it('returns zero for an empty list', () => {
    expect(floatBalanceForMachine([], 'm1', 'b1')).toBe(0)
  })
})

describe('totalChangeFloat', () => {
  it('sums every row', () => {
    expect(totalChangeFloat(rows)).toBe(145)
  })

  it('returns zero for an empty list', () => {
    expect(totalChangeFloat([])).toBe(0)
  })
})
