/**
 * Run: deno test Docker/supabase/functions/deal-search/offer-date.test.ts
 */
import { assertEquals } from 'jsr:@std/assert'
import { toOfferDate } from './offer-date.ts'

Deno.test('local-midnight start in UTC maps to the next calendar day (CEST)', () => {
  assertEquals(toOfferDate('2026-05-03T22:00:00Z'), '2026-05-04')
})

Deno.test('local-midnight start in UTC maps to the next calendar day (CET)', () => {
  assertEquals(toOfferDate('2026-01-11T23:00:00Z'), '2026-01-12')
})

Deno.test('end-of-day until stays on the same calendar day', () => {
  assertEquals(toOfferDate('2026-05-09T21:59:00Z'), '2026-05-09')
})

Deno.test('plain dates pass through, empty/invalid become null', () => {
  assertEquals(toOfferDate('2026-05-04'), '2026-05-04')
  assertEquals(toOfferDate(null), null)
  assertEquals(toOfferDate(''), null)
  assertEquals(toOfferDate('not a date'), null)
})

Deno.test('honours the company timezone, falls back on an invalid one', () => {
  assertEquals(toOfferDate('2026-05-03T22:00:00Z', 'UTC'), '2026-05-03')
  assertEquals(toOfferDate('2026-05-03T22:00:00Z', 'Not/AZone'), '2026-05-04')
})
