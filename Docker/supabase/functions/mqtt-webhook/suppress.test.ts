// Use the same std-assert specifier the repo's existing mdb-log.test.ts uses.
import { assertEquals } from "jsr:@std/assert";
import {
  decideSuppress,
  rebootCorroborates,
  REBOOT_CORRELATION_FORWARD_MS,
  REBOOT_CORRELATION_WINDOW_MS,
  SUPPRESS_WINDOW_MS,
} from "./suppress.ts";

const T = 1_700_000_000_000; // fixed base ms

Deno.test("not suppressed when time_uncertain is false (even with a match)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: false, createdAtMs: T }, [{ id: "a", createdAtMs: T, timeUncertain: false }]),
    null,
  );
});

Deno.test("suppressed (returns matched id) when time_uncertain + candidate within window", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + 5_000, timeUncertain: false }]),
    "a",
  );
});

Deno.test("not suppressed when the only candidate is outside the window", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + SUPPRESS_WINDOW_MS + 1, timeUncertain: false }]),
    null,
  );
});

Deno.test("not suppressed when there are no candidates", () => {
  assertEquals(decideSuppress({ timeUncertain: true, createdAtMs: T }, []), null);
});

Deno.test("window is symmetric (candidate slightly before also matches)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "b", createdAtMs: T - 10_000, timeUncertain: false }]),
    "b",
  );
});

Deno.test("suppressed at exactly the window boundary (<= is inclusive)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "c", createdAtMs: T + SUPPRESS_WINDOW_MS, timeUncertain: false }]),
    "c",
  );
});

// --- candidate time_uncertain gate -----------------------------------------
// Regression cover for the offline-drain sale loss: when a device with no
// clock reconnects it publishes its whole buffered NVS queue at once, and the
// webhook stamps every one of those sales with its own receive time. They are
// distinct vends that merely *look* simultaneous, so none of them may be
// treated as a brownout re-report of another.

Deno.test("not suppressed when the only candidate is itself time_uncertain (offline queue drain)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + 1_000, timeUncertain: true }]),
    null,
  );
});

Deno.test("a whole drain burst of identical sales suppresses nothing", () => {
  // Six identical vends buffered during an outage, all landing within 3s.
  const burst = [0, 500, 1_000, 1_500, 2_000, 2_500].map((d, i) => ({
    id: `b${i}`,
    createdAtMs: T + d,
    timeUncertain: true,
  }));
  for (const incoming of burst) {
    const others = burst.filter((c) => c.id !== incoming.id);
    assertEquals(decideSuppress({ timeUncertain: true, createdAtMs: incoming.createdAtMs }, others), null);
  }
});

Deno.test("still suppresses against a certain-clock original (the real brownout pair)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [
      { id: "drain-sibling", createdAtMs: T + 1_000, timeUncertain: true },
      { id: "original", createdAtMs: T - 12_000, timeUncertain: false },
    ]),
    "original",
  );
});

// --- rebootCorroborates ----------------------------------------------------

Deno.test("rebootCorroborates: false when no restarts recorded", () => {
  assertEquals(rebootCorroborates([], T), false);
});

Deno.test("rebootCorroborates: true for a restart shortly before the sale", () => {
  assertEquals(rebootCorroborates([T - 5_000], T), true);
});

Deno.test("rebootCorroborates: true at the backward window boundary (inclusive)", () => {
  assertEquals(rebootCorroborates([T - REBOOT_CORRELATION_WINDOW_MS], T), true);
});

Deno.test("rebootCorroborates: false for a restart older than the window (e.g. morning reboot, afternoon sale)", () => {
  assertEquals(rebootCorroborates([T - REBOOT_CORRELATION_WINDOW_MS - 1], T), false);
});

Deno.test("rebootCorroborates: true for a restart marginally after (event ordering skew)", () => {
  assertEquals(rebootCorroborates([T + REBOOT_CORRELATION_FORWARD_MS], T), true);
});

Deno.test("rebootCorroborates: false for a restart well after the sale", () => {
  assertEquals(rebootCorroborates([T + REBOOT_CORRELATION_FORWARD_MS + 1], T), false);
});

Deno.test("rebootCorroborates: true if any one of several restarts falls in window", () => {
  assertEquals(rebootCorroborates([T - 3_600_000, T - 2_000, T + 999_999], T), true);
});
