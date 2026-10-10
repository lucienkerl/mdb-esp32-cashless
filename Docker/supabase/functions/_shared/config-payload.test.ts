// Same std-assert specifier the repo's other edge-function tests use.
import { assertEquals } from "jsr:@std/assert";
import { buildConfigPayload, CMD_MDB_TRACE } from "./config-payload.ts";

const PASSKEY = "abcdefghijklmnopqr"; // 18 chars, like the device's passkey

/** What the firmware's xorDecodeWithPasskey() does, minus the clock check. */
function decode(payload: Uint8Array, passkey: string) {
  const p = Uint8Array.from(payload);
  for (let x = 0; x < passkey.length; x++) p[x + 1] ^= passkey.charCodeAt(x);

  let chk = 0;
  for (let x = 0; x < 18; x++) chk += p[x];

  return {
    cmd: p[0],
    checksumOk: (chk & 0xff) === p[18],
    param: ((p[2] << 24) | (p[3] << 16) | (p[4] << 8) | p[5]) >>> 0,
    item: (p[6] << 8) | p[7],
    timestamp: ((p[8] << 24) | (p[9] << 16) | (p[10] << 8) | p[11]) >>> 0,
  };
}

Deno.test("a trace request carries its duration in the raw itemNumber field", () => {
  const d = decode(buildConfigPayload(CMD_MDB_TRACE, 0, PASSKEY, 300, 1_800_000_000), PASSKEY);
  assertEquals(d.cmd, 0x35);
  assertEquals(d.item, 300);
  assertEquals(d.param, 0);
  assertEquals(d.timestamp, 1_800_000_000);
  assertEquals(d.checksumOk, true);
});

Deno.test("param and item are independent and survive the full range", () => {
  for (const [param, item] of [[0, 0], [1, 0], [2, 65535], [0x01020304, 0x0506]]) {
    const d = decode(buildConfigPayload(0x31, param, PASSKEY, item, 1_800_000_000), PASSKEY);
    assertEquals([d.param, d.item], [param, item]);
    assertEquals(d.checksumOk, true);
  }
});

Deno.test("item defaults to 0, so existing commands are byte-compatible", () => {
  const d = decode(buildConfigPayload(0x30, 0, PASSKEY), PASSKEY);
  assertEquals(d.item, 0);
  assertEquals(d.checksumOk, true);
});

Deno.test("a wrong passkey fails the checksum instead of decoding", () => {
  const payload = buildConfigPayload(CMD_MDB_TRACE, 0, PASSKEY, 300);
  assertEquals(decode(payload, "rqponmlkjihgfedcba").checksumOk, false);
});
