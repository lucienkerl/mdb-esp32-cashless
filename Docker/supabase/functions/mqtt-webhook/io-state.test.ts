import { assertEquals, assertThrows } from 'jsr:@std/assert'
import { InvalidIoStateError, parseIoState } from './io-state.ts'

Deno.test('parses a full snapshot', () => {
  const s = parseIoState(
    '{"active":true,"left":118,"in":[1,1,0],"relay":[0,1],"ntc":24.6,"ow":[[{"id":"28ff64a1b2c30405","t":21.50}],[]]}',
  )
  assertEquals(s, {
    active: true,
    left: 118,
    in: [1, 1, 0],
    relay: [0, 1],
    ntc: 24.6,
    ow: [[{ id: '28FF64A1B2C30405', t: 21.5 }], []],
  })
})

Deno.test('ntc and ow are optional, a device without temperature keeps its id', () => {
  assertEquals(parseIoState('{"active":false,"left":0,"in":[0,0,0],"relay":[0,0]}'), {
    active: false, left: 0, in: [0, 0, 0], relay: [0, 0],
  })
  const s = parseIoState('{"active":true,"left":5,"in":[1,1,1],"relay":[1,0],"ow":[[],[{"id":"0100000000000001"}]]}')
  assertEquals(s.ow, [[], [{ id: '0100000000000001' }]])
})

Deno.test('rejects malformed payloads', () => {
  for (const bad of [
    'not json',
    '[]',
    '{"in":[1,1,1],"relay":[0,0]}',
    '{"active":true,"in":[1,1],"relay":[0,0]}',
    '{"active":true,"in":[1,1,2],"relay":[0,0]}',
    '{"active":true,"in":[1,1,1],"relay":[0]}',
    '{"active":true,"in":[1,1,1],"relay":[0,0],"ow":[[]]}',
    '{"active":true,"in":[1,1,1],"relay":[0,0],"ow":[[{"id":"xyz"}],[]]}',
  ]) {
    assertThrows(() => parseIoState(bad), InvalidIoStateError)
  }
})
