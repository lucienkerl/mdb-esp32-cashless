/**
 * Per-machine MDB/DEX selection-number offset.
 *
 * Some VMCs number their selections densely from 1 while the front labels read
 * two-digit tray.column. The offset is added at ingest so the stored number
 * matches what the customer pressed and what the tray table holds.
 *
 * Pure functions only — no DB, no I/O — so they stay unit-testable.
 */

export interface SlotCounter {
  vends: number;
  value_cents: number;
}

/** MDB uses 0xFFFF for "item number unknown / not applicable". */
const ITEM_NUMBER_UNKNOWN = 0xffff;

/**
 * effective = raw + offset.
 *
 * `0xFFFF` passes through untouched — it is a sentinel, not a selection.
 * The result is clamped at 0: a misconfigured offset should make the tray join
 * miss visibly, not write negative keys that corrupt later comparisons.
 */
export function applyItemOffset(raw: number, offset: number): number {
  if (offset === 0) return raw;
  if (raw === ITEM_NUMBER_UNKNOWN) return raw;
  return Math.max(0, raw + offset);
}

/**
 * Re-key a parsed DEX `slot_counters` map through `rekey`.
 *
 * DEX PA1 selection ids arrive as strings and may be zero-padded ("01"), so the
 * keys are normalised to their decimal form on the way through. Non-numeric
 * keys are passed through untouched. On a key collision the higher `vends`
 * counter wins — dropping the smaller one is safer than merging two lifetime
 * counters into a number that never existed.
 */
export function rekeySlotCounters(
  counters: Record<string, SlotCounter>,
  rekey: (itemNumber: number) => number,
): Record<string, SlotCounter> {
  const out: Record<string, SlotCounter> = {};
  for (const [key, value] of Object.entries(counters)) {
    if (!/^\d+$/.test(key)) {
      out[key] = value;
      continue;
    }
    const target = String(rekey(parseInt(key, 10)));
    const existing = out[target];
    if (existing && existing.vends >= value.vends) continue;
    out[target] = value;
  }
  return out;
}

/** Shift the keys of a parsed DEX `slot_counters` map by the same offset. */
export function shiftSlotCounters(
  counters: Record<string, SlotCounter>,
  offset: number,
): Record<string, SlotCounter> {
  if (offset === 0) return counters;
  return rekeySlotCounters(counters, (itemNumber) => applyItemOffset(itemNumber, offset));
}
