// Same std-assert specifier the repo's other edge-function tests use.
import { assertEquals } from "jsr:@std/assert";
import {
  CARD_CMD,
  CARD_PAYLOAD_VERSION,
  clampCredit,
  decodeCardPayload,
  MAX_CARD_CREDIT_EUR,
} from "./card-payload.ts";

const PASSKEY = "Ab3!x9Qz_7@LmP0#tV"; // 18 chars, like the ones claim-device hands out

/**
 * Mirror of mdb-slave-esp32s3.c::card_payload_encode. Keeping an independent
 * encoder here is the point of the test: if either side of the wire format
 * drifts, these assertions stop matching.
 */
function encode(uid: number[], opts?: { cardType?: number; ts?: number; version?: number; passkey?: string }): Uint8Array {
  const passkey = opts?.passkey ?? PASSKEY;
  const ts = opts?.ts ?? 1_760_000_000;
  const buf = new Uint8Array(9 + uid.length);

  buf[0] = CARD_CMD;
  buf[1] = opts?.version ?? CARD_PAYLOAD_VERSION;
  buf[2] = (ts >> 24) & 0xff;
  buf[3] = (ts >> 16) & 0xff;
  buf[4] = (ts >> 8) & 0xff;
  buf[5] = ts & 0xff;
  buf[6] = opts?.cardType ?? 0x02;
  buf[7] = uid.length;
  uid.forEach((b, i) => (buf[8 + i] = b));

  let chk = 0;
  for (let i = 0; i < buf.length - 1; i++) chk += buf[i];
  buf[buf.length - 1] = chk & 0xff;

  const cipher = [...passkey].map((c) => c.charCodeAt(0));
  for (let i = 1; i < buf.length; i++) buf[i] ^= cipher[(i - 1) % cipher.length];

  return buf;
}

Deno.test("decodes a 4-byte UID round trip", () => {
  const res = decodeCardPayload(encode([0x04, 0xa1, 0xb2, 0xc3]), PASSKEY);
  assertEquals(res.ok, true);
  if (!res.ok) return;
  assertEquals(res.card.uidHex, "04A1B2C3");
  assertEquals(res.card.uidLength, 4);
  assertEquals(res.card.cardType, 0x02);
  assertEquals(res.card.timestampSec, 1_760_000_000);
});

Deno.test("decodes UID lengths the XOR key length does not divide evenly", () => {
  // 10-byte UID means the 18-byte passkey wraps mid-payload — the wrap is
  // exactly where a firmware/backend mismatch would show up first.
  const uid = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
  const res = decodeCardPayload(encode(uid), PASSKEY);
  assertEquals(res.ok, true);
  if (!res.ok) return;
  assertEquals(res.card.uidHex, "0102030405060708090A");
});

Deno.test("leading zero bytes survive as hex", () => {
  const res = decodeCardPayload(encode([0x00, 0x00, 0x0f, 0xff, 0x00]), PASSKEY);
  assertEquals(res.ok, true);
  if (!res.ok) return;
  assertEquals(res.card.uidHex, "00000FFF00");
});

Deno.test("rejects a payload encoded with a different passkey", () => {
  const res = decodeCardPayload(encode([1, 2, 3, 4], { passkey: "zzzzzzzzzzzzzzzzzz" }), PASSKEY);
  assertEquals(res.ok, false);
});

Deno.test("rejects a flipped bit in the card data", () => {
  const buf = encode([0x04, 0xa1, 0xb2, 0xc3]);
  buf[9] ^= 0x01;
  const res = decodeCardPayload(buf, PASSKEY);
  assertEquals(res, { ok: false, error: "checksum mismatch" });
});

Deno.test("rejects a truncated payload", () => {
  const buf = encode([0x04, 0xa1, 0xb2, 0xc3]).slice(0, 8);
  assertEquals(decodeCardPayload(buf, PASSKEY).ok, false);
});

Deno.test("rejects a uid length that disagrees with the payload size", () => {
  // Re-encode by hand with a lying length byte so the checksum still matches.
  const uid = [1, 2, 3, 4];
  const buf = new Uint8Array(9 + uid.length);
  buf[0] = CARD_CMD;
  buf[1] = CARD_PAYLOAD_VERSION;
  buf[7] = 9; // claims 9 bytes of UID in a 4-byte frame
  uid.forEach((b, i) => (buf[8 + i] = b));
  let chk = 0;
  for (let i = 0; i < buf.length - 1; i++) chk += buf[i];
  buf[buf.length - 1] = chk & 0xff;
  const cipher = [...PASSKEY].map((c) => c.charCodeAt(0));
  for (let i = 1; i < buf.length; i++) buf[i] ^= cipher[(i - 1) % cipher.length];

  assertEquals(decodeCardPayload(buf, PASSKEY).ok, false);
});

Deno.test("rejects an unknown payload version", () => {
  const res = decodeCardPayload(encode([1, 2, 3, 4], { version: 0x02 }), PASSKEY);
  assertEquals(res.ok, false);
});

Deno.test("clampCredit floors negatives and zero at 0", () => {
  assertEquals(clampCredit(-5), 0);
  assertEquals(clampCredit(0), 0);
  assertEquals(clampCredit(Number.NaN), 0);
});

Deno.test("clampCredit rounds to cents and caps at the MDB uint16 ceiling", () => {
  assertEquals(clampCredit(2.499999999), 2.5);
  assertEquals(clampCredit(10.005), 10.01);
  assertEquals(clampCredit(10_000), MAX_CARD_CREDIT_EUR);
});
