import { assertEquals, assertStrictEquals } from 'jsr:@std/assert';
import { buildTrayMap, mapSlotCounters, resolveItemNumber } from './tray-mapping.ts';
import { shiftSlotCounters } from './slot-offset.ts';

// Labels 10-12 on the first row, 20-21 on the second; the machine numbers its
// selections densely from 1, so no constant offset fits both rows.
const trays = [
  { item_number: 10, internal_item_number: 1 },
  { item_number: 11, internal_item_number: 2 },
  { item_number: 12, internal_item_number: 3 },
  { item_number: 20, internal_item_number: 4 },
  { item_number: 21, internal_item_number: 5 },
  { item_number: 30, internal_item_number: null },
];

Deno.test('buildTrayMap: only trays with an internal number take part', () => {
  const map = buildTrayMap(trays);
  assertEquals(map.size, 5);
  assertEquals(map.get(4), 20);
  assertEquals(map.has(30), false);
});

Deno.test('resolveItemNumber: a mapped number resolves to the tray label', () => {
  const map = buildTrayMap(trays);
  assertEquals(resolveItemNumber(1, map, 0), 10);
  assertEquals(resolveItemNumber(3, map, 0), 12);
  assertEquals(resolveItemNumber(4, map, 0), 20);
});

Deno.test('resolveItemNumber: an unmapped number is kept as reported', () => {
  assertEquals(resolveItemNumber(30, buildTrayMap(trays), 0), 30);
  assertEquals(resolveItemNumber(7, buildTrayMap([]), 0), 7);
});

Deno.test('resolveItemNumber: an unmapped number falls back to the machine offset', () => {
  assertEquals(resolveItemNumber(7, buildTrayMap(trays), 9), 16);
});

Deno.test('resolveItemNumber: the tray mapping wins over the machine offset', () => {
  assertEquals(resolveItemNumber(4, buildTrayMap(trays), 9), 20);
});

Deno.test('resolveItemNumber: leaves the MDB "unknown item" sentinel alone', () => {
  assertEquals(resolveItemNumber(0xffff, buildTrayMap(trays), 9), 0xffff);
});

Deno.test('mapSlotCounters: no mapping and no offset returns the parsed map untouched', () => {
  const input = { '01': { vends: 5, value_cents: 250 } };
  assertStrictEquals(mapSlotCounters(input, buildTrayMap([]), 0), input);
});

Deno.test('mapSlotCounters: no mapping behaves exactly like the offset alone', () => {
  const input = {
    '01': { vends: 5, value_cents: 250 },
    '2': { vends: 7, value_cents: 350 },
  };
  assertEquals(mapSlotCounters(input, buildTrayMap([]), 9), shiftSlotCounters(input, 9));
});

Deno.test('mapSlotCounters: re-keys mapped selections to their labels', () => {
  const input = {
    '03': { vends: 5, value_cents: 250 },
    '4': { vends: 7, value_cents: 350 },
    '30': { vends: 2, value_cents: 100 },
    'ZZ': { vends: 1, value_cents: 50 },
  };
  assertEquals(mapSlotCounters(input, buildTrayMap(trays), 0), {
    '12': { vends: 5, value_cents: 250 },
    '20': { vends: 7, value_cents: 350 },
    '30': { vends: 2, value_cents: 100 },
    'ZZ': { vends: 1, value_cents: 50 },
  });
});

Deno.test('mapSlotCounters: unmapped selections still get the machine offset', () => {
  const input = {
    '1': { vends: 5, value_cents: 250 },
    '7': { vends: 3, value_cents: 150 },
  };
  assertEquals(mapSlotCounters(input, buildTrayMap(trays), 9), {
    '10': { vends: 5, value_cents: 250 },
    '16': { vends: 3, value_cents: 150 },
  });
});
