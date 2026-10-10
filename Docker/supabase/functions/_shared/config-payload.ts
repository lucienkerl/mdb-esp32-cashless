/**
 * The 19-byte XOR-encrypted payload the firmware's `/config` handler decodes
 * with `xorDecodeWithPasskey()` (mdb-slave-esp32s3.c). Same binary layout as
 * send-credit:
 *
 *   [0]      cmd
 *   [1]      version (0x01)
 *   [2..5]   param      — big-endian u32; the firmware runs it through the MDB
 *                         scale factor, so use it for small flags/selectors
 *                         that are fine being scaled (they are 0, 1, 2)
 *   [6..7]   itemNumber — big-endian u16; read RAW by the firmware, so this is
 *                         the field for a plain count such as a duration
 *   [8..11]  unix timestamp (seconds) — the device accepts ±8 s
 *   [12..17] random padding
 *   [18]     checksum: sum of bytes 0..17
 *
 * Bytes [1..18] are XORed with the device passkey.
 */

// Config command bytes (must match ESP32 firmware)
export const CMD_RESTART = 0x30
export const CMD_MDB_ADDRESS = 0x31
export const CMD_MDB_RESET = 0x32
/** Live MDB bus trace: itemNumber = seconds to trace, 0 = stop. */
export const CMD_MDB_TRACE = 0x35

/** The firmware clamps to the same cap (MDB_TRACE_MAX_SECONDS). */
export const MDB_TRACE_MAX_SECONDS = 1800

export function buildConfigPayload(
  cmd: number,
  param: number,
  passkey: string,
  item = 0,
  nowSec = Math.floor(Date.now() / 1000),
): Uint8Array {
  const payload = new Uint8Array(19)
  crypto.getRandomValues(payload) // fill with random (padding bytes stay random)

  payload[0] = cmd
  payload[1] = 0x01                            // version v1
  payload[2] = (param >> 24) & 0xff            // param (big-endian u32)
  payload[3] = (param >> 16) & 0xff
  payload[4] = (param >> 8) & 0xff
  payload[5] = (param >> 0) & 0xff
  payload[6] = (item >> 8) & 0xff              // itemNumber (big-endian u16)
  payload[7] = (item >> 0) & 0xff
  payload[8] = (nowSec >> 24) & 0xff           // timestamp
  payload[9] = (nowSec >> 16) & 0xff
  payload[10] = (nowSec >> 8) & 0xff
  payload[11] = (nowSec >> 0) & 0xff

  // Checksum: sum of bytes 0..17
  let chk = 0
  for (let i = 0; i < 18; i++) chk += payload[i]
  payload[18] = chk & 0xff

  // XOR bytes 1..18 with passkey
  const cipher = [...passkey].map((c: string) => c.charCodeAt(0))
  for (let k = 0; k < cipher.length; k++) {
    payload[k + 1] ^= cipher[k]
  }

  return payload
}
