/**
 * Decoder for the RFID card-presentation payload (cmd 0x25) published by the
 * firmware on /{company_id}/{device_id}/card.
 *
 * The 19-byte sale payload has no room for a card serial, so card reads use
 * their own variable-length layout. Security envelope is unchanged: passkey
 * XOR, a unix timestamp and a sum checksum.
 *
 *   byte 0        cmd      0x25
 *   byte 1        version  0x01
 *   bytes 2-5     unix timestamp, big endian
 *   byte 6        card type (reader-specific)
 *   byte 7        uid length N (1..16)
 *   bytes 8..7+N  card serial, MSB first
 *   byte 8+N      checksum = sum(bytes 0..7+N) & 0xFF
 *
 * XOR covers bytes 1..8+N with passkey[(i - 1) % passkey.length], mirroring
 * mdb-slave-esp32s3.c::card_payload_encode.
 */

export const CARD_CMD = 0x25;
export const CARD_PAYLOAD_VERSION = 0x01;
export const CARD_UID_MAX_BYTES = 16;

export interface CardPresentation {
  cardType: number;
  uidHex: string;
  uidLength: number;
  timestampSec: number;
}

export type CardDecodeResult =
  | { ok: true; card: CardPresentation }
  | { ok: false; error: string };

export function decodeCardPayload(raw: Uint8Array, passkey: string): CardDecodeResult {
  const minLen = 9 + 1;
  const maxLen = 9 + CARD_UID_MAX_BYTES;

  if (raw.length < minLen || raw.length > maxLen) {
    return { ok: false, error: `invalid card payload length ${raw.length}` };
  }
  if (!passkey) {
    return { ok: false, error: 'device has no passkey' };
  }

  const cipher = [...passkey].map((c) => c.charCodeAt(0));
  const buf = new Uint8Array(raw);

  for (let i = 1; i < buf.length; i++) {
    buf[i] ^= cipher[(i - 1) % cipher.length];
  }

  if (buf[0] !== CARD_CMD) {
    return { ok: false, error: `unexpected cmd 0x${buf[0].toString(16)}` };
  }
  if (buf[1] !== CARD_PAYLOAD_VERSION) {
    return { ok: false, error: `unsupported card payload version ${buf[1]}` };
  }

  const uidLength = buf[7];
  if (uidLength < 1 || uidLength > CARD_UID_MAX_BYTES || buf.length !== 9 + uidLength) {
    return { ok: false, error: `uid length ${uidLength} does not match payload` };
  }

  let chk = 0;
  for (let i = 0; i < buf.length - 1; i++) chk += buf[i];
  if ((chk & 0xff) !== buf[buf.length - 1]) {
    return { ok: false, error: 'checksum mismatch' };
  }

  const timestampSec =
    ((buf[2] << 24) | (buf[3] << 16) | (buf[4] << 8) | buf[5]) >>> 0;

  const uidHex = Array.from(buf.slice(8, 8 + uidLength))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
    .toUpperCase();

  return {
    ok: true,
    card: { cardType: buf[6], uidHex, uidLength, timestampSec },
  };
}

/**
 * The MDB credit field the firmware fills is a uint16 of scaled cents, so
 * anything above 655.35 EUR would wrap around and hand the customer a
 * near-zero (or wrong) balance. Clamp instead, and never send a negative
 * balance — 0 tells the reader to cancel the session, which is what an
 * overdrawn card should do.
 */
export const MAX_CARD_CREDIT_EUR = 655.35;

export function clampCredit(balanceEur: number): number {
  if (!Number.isFinite(balanceEur) || balanceEur <= 0) return 0;
  return Math.min(Math.round(balanceEur * 100) / 100, MAX_CARD_CREDIT_EUR);
}
