/**
 * Tests for the mdb-trace batch parser used by mqtt-webhook.
 *
 * Run: deno test Docker/supabase/functions/mqtt-webhook/mdb-trace.test.ts
 */

import { assertEquals, assertThrows } from 'jsr:@std/assert'
import {
  InvalidTraceError,
  MAX_FRAMES_PER_BATCH,
  MAX_WORDS_PER_FRAME,
  parseMdbTrace,
} from './mdb-trace.ts'

Deno.test('parses a firmware batch', () => {
  const batch = parseMdbTrace('{"drop":3,"f":[[12,"t","10B"],[9,"r","1120FF"]]}')
  assertEquals(batch, {
    dropped: 3,
    frames: [
      [12, 't', '10B'],
      [9, 'r', '1120FF'],
    ],
  })
})

Deno.test('drop is optional and defaults to 0', () => {
  assertEquals(parseMdbTrace('{"f":[[0,"r","112"]]}').dropped, 0)
})

Deno.test('rejects anything that is not a batch', () => {
  for (const bad of [
    'not json',
    'null',
    '[]',
    '{}',
    '{"f":[]}',
    '{"f":"112"}',
    '{"drop":-1,"f":[[0,"r","112"]]}',
    '{"drop":1.5,"f":[[0,"r","112"]]}',
    '{"drop":"3","f":[[0,"r","112"]]}',
  ]) {
    assertThrows(() => parseMdbTrace(bad), InvalidTraceError, undefined, `should reject ${bad}`)
  }
})

Deno.test('rejects malformed frames', () => {
  for (const frame of [
    '[0,"r"]',                 // too short
    '[0,"r","112",1]',         // too long
    '["0","r","112"]',         // age not a number
    '[-1,"r","112"]',          // negative age
    '[1.5,"r","112"]',         // fractional age
    '[999999999999,"r","112"]', // absurd age
    '[0,"x","112"]',           // unknown direction
    '[0,"r",""]',              // no words
    '[0,"r","11"]',            // not a multiple of 3
    '[0,"r","11g"]',           // not hex
    '[0,"r","11a"]',           // lower case
    '[0,"r","200"]',           // above 9 bits
    '[0,"r",112]',             // words not a string
  ]) {
    assertThrows(
      () => parseMdbTrace(`{"f":[${frame}]}`),
      InvalidTraceError,
      undefined,
      `should reject ${frame}`,
    )
  }
})

Deno.test('enforces the size limits', () => {
  const ok = '1FF'.repeat(MAX_WORDS_PER_FRAME)
  assertEquals(parseMdbTrace(`{"f":[[0,"r","${ok}"]]}`).frames.length, 1)
  assertThrows(() => parseMdbTrace(`{"f":[[0,"r","${ok}000"]]}`), InvalidTraceError)

  const frames = (n: number) => JSON.stringify({ f: Array.from({ length: n }, () => [0, 'r', '112']) })
  assertEquals(parseMdbTrace(frames(MAX_FRAMES_PER_BATCH)).frames.length, MAX_FRAMES_PER_BATCH)
  assertThrows(() => parseMdbTrace(frames(MAX_FRAMES_PER_BATCH + 1)), InvalidTraceError)
})
