/**
 * Convert a provider validity timestamp into the calendar day it falls on in
 * the company's timezone, for the `deal_cache.valid_from/valid_until` DATE
 * columns.
 *
 * Why: Marktguru sends local-midnight boundaries as UTC instants — an offer
 * valid from Monday 04.05. arrives as `2026-05-03T22:00:00Z`. Casting that
 * string straight into a Postgres `date` keeps the UTC calendar day
 * (2026-05-03), so every offer looked valid one day before it actually
 * starts. `validUntil` (`…T21:59:00Z` = 23:59 local) happened to survive
 * the cast, which is why only the start day was off.
 *
 * Plain `YYYY-MM-DD` inputs are passed through unchanged; unparseable input
 * falls back to null (treated as open-ended) rather than a wrong date.
 */
export function toOfferDate(value: string | null | undefined, timeZone = 'Europe/Berlin'): string | null {
  if (!value) return null
  if (/^\d{4}-\d{2}-\d{2}$/.test(value)) return value
  const instant = new Date(value)
  if (Number.isNaN(instant.getTime())) return null
  let fmt: Intl.DateTimeFormat
  try {
    fmt = new Intl.DateTimeFormat('en-CA', { timeZone, year: 'numeric', month: '2-digit', day: '2-digit' })
  } catch {
    fmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Berlin', year: 'numeric', month: '2-digit', day: '2-digit' })
  }
  // en-CA formats as YYYY-MM-DD.
  return fmt.format(instant)
}
