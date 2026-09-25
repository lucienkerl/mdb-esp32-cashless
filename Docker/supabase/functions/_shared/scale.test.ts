// Same std-assert specifier the repo's other edge-function tests use.
import { assertEquals } from "jsr:@std/assert";
import { eurToScaleUnits, scaleUnitsToEur } from "./scale.ts";

/** The conversion this replaced, kept to show what it got wrong. */
function truncatingToScaleFactor(p: number): number {
  const v = p / 1 / Math.pow(10, -2);
  return v | 0; // what the bitwise payload packing did to it
}

Deno.test("the reported case: 8.20 EUR is 820 units, not 819", () => {
  assertEquals(eurToScaleUnits(8.20), 820);
  // The regression itself — this is where the first of two lost cents came from.
  assertEquals(truncatingToScaleFactor(8.20), 819);
});

Deno.test("every cent amount up to the MDB uint16 ceiling round-trips", () => {
  const wrong: number[] = [];
  for (let cents = 0; cents <= 65535; cents++) {
    if (eurToScaleUnits(cents / 100) !== cents) wrong.push(cents);
  }
  assertEquals(wrong, []);
});

Deno.test("the old conversion really was lossy across that range", () => {
  let lossy = 0;
  for (let cents = 0; cents <= 65535; cents++) {
    if (truncatingToScaleFactor(cents / 100) !== cents) lossy++;
  }
  // Not an exact figure to defend, just proof the test above is meaningful.
  assertEquals(lossy > 0, true);
});

Deno.test("returns a whole number of units for awkward float balances", () => {
  // What a float8 balance column hands us after a few subtractions.
  assertEquals(eurToScaleUnits(7.390000000000001), 739);
  assertEquals(eurToScaleUnits(6.239999999999999), 624);
  assertEquals(eurToScaleUnits(0.1 + 0.2), 30);
});

Deno.test("handles zero and non-finite input without producing junk", () => {
  assertEquals(eurToScaleUnits(0), 0);
  assertEquals(eurToScaleUnits(Number.NaN), 0);
  assertEquals(eurToScaleUnits(Number.POSITIVE_INFINITY), 0);
});

Deno.test("scaleUnitsToEur is the inverse for whole cents", () => {
  assertEquals(scaleUnitsToEur(820), 8.2);
  assertEquals(scaleUnitsToEur(0), 0);
});
