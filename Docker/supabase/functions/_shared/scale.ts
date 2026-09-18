/**
 * Currency <-> MDB scale-factor conversion.
 *
 * MDB carries prices as integers in "scale factor units" — at the scale
 * factor 1 / 2 decimal places this project configures, that is plain cents.
 *
 * The conversion looks like it should be `amount / Math.pow(10, -2)`, and it
 * was written that way originally, but `Math.pow(10, -2)` is not exactly
 * 0.01 (it is a hair above), so the divide lands just below the integer it
 * should hit: 8.20 becomes 819.9999999999999. Everything downstream turns
 * that into an integer by truncating — the bitwise packing here, and the
 * firmware's own conversion on the far side — so the two truncations
 * compound and a balance of 8.20 reaches the machine as 8.18.
 *
 * Multiply and round instead. 253 of the first 2000 cent amounts were
 * affected by the old form; none are by this one (see scale.test.ts).
 */
export function eurToScaleUnits(amountEur: number): number {
  if (!Number.isFinite(amountEur)) return 0
  return Math.round(amountEur * 100)
}

/** Scale-factor units back to EUR, for logging and API responses. */
export function scaleUnitsToEur(units: number): number {
  return units / 100
}
