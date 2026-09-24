/**
 * Per-tray mapping from the selection number a machine REPORTS (over MDB, and
 * as the PA1 id in its DEX audit) to the slot number on the tray's label.
 *
 * `machine_trays.item_number` is the labelled number; `internal_item_number`,
 * when set, is what the machine reports for that same tray. The explicit tray
 * mapping wins over the per-machine offset: it exists for machines whose
 * numbering no constant offset can describe. Numbers without a mapping fall
 * back to the offset, which is 0 unless configured, so a machine with neither
 * behaves exactly as before either existed.
 *
 * Pure functions only — no DB, no I/O — so they stay unit-testable.
 */

import { applyItemOffset, rekeySlotCounters, shiftSlotCounters, type SlotCounter } from './slot-offset.ts';

export interface TrayMappingRow {
  item_number: number;
  internal_item_number: number | null;
}

/** Reported (internal) number → labelled slot number, for one machine. */
export type TrayMap = ReadonlyMap<number, number>;

export function buildTrayMap(rows: readonly TrayMappingRow[]): TrayMap {
  const map = new Map<number, number>();
  for (const row of rows) {
    if (row.internal_item_number == null) continue;
    map.set(row.internal_item_number, row.item_number);
  }
  return map;
}

/** The slot number a sale reported as `raw` belongs to. */
export function resolveItemNumber(raw: number, trayMap: TrayMap, offset: number): number {
  return trayMap.get(raw) ?? applyItemOffset(raw, offset);
}

/**
 * Re-key a parsed DEX `slot_counters` map the same way the sale path resolves
 * item numbers, so DEX counters and `sales.item_number` stay in one number
 * space.
 */
export function mapSlotCounters(
  counters: Record<string, SlotCounter>,
  trayMap: TrayMap,
  offset: number,
): Record<string, SlotCounter> {
  if (trayMap.size === 0) return shiftSlotCounters(counters, offset);
  return rekeySlotCounters(counters, (itemNumber) => resolveItemNumber(itemNumber, trayMap, offset));
}
