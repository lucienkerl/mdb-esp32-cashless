import { describe, it, expect } from 'vitest'
import { changeFloatAmount } from '../useCashBook'

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
