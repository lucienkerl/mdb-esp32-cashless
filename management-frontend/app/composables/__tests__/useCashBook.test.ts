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
})

describe('floatBalanceForMachine', () => {
  it('sums a machine across cash books', () => {
    expect(floatBalanceForMachine(rows, 'm1')).toBe(65)
  })

  it('returns the single balance for a machine in one cash book', () => {
    expect(floatBalanceForMachine(rows, 'm2')).toBe(80)
  })

  it('returns zero for a machine with no float', () => {
    expect(floatBalanceForMachine(rows, 'unknown')).toBe(0)
  })

  it('returns zero for an empty list', () => {
    expect(floatBalanceForMachine([], 'm1')).toBe(0)
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
