/**
 * I/O test snapshot published by WROOM-1U firmware on `/{company}/{device}/io`
 * while the machine's "I/O test" tab runs a test (config cmd 0x36):
 *
 *   {"active":true,"left":118,"in":[1,1,0],"relay":[0,1],"ntc":24.6,
 *    "ow":[[{"id":"28FF64A1B2C30405","t":21.50}],[]]}
 *
 * `ntc` is missing when the ADC read failed, `ow` until the first 1-Wire scan
 * finished, `t` for a device that is not a DS18B20 or could not be read.
 * Plaintext like mdb-log: it carries no money and the test only starts on an
 * authenticated, XOR-encrypted admin command.
 */
export interface OneWireDevice {
  id: string
  t?: number
}

export interface IoState {
  active: boolean
  left: number
  in: number[]
  relay: number[]
  ntc?: number
  ow?: OneWireDevice[][]
}

export class InvalidIoStateError extends Error {}

const isLevel = (v: unknown): v is number => v === 0 || v === 1

export function parseIoState(raw: string): IoState {
  let json: unknown
  try {
    json = JSON.parse(raw)
  } catch {
    throw new InvalidIoStateError('invalid JSON in io payload')
  }
  if (!json || typeof json !== 'object' || Array.isArray(json)) {
    throw new InvalidIoStateError('io payload must be an object')
  }
  const o = json as Record<string, unknown>

  if (typeof o.active !== 'boolean') throw new InvalidIoStateError('missing active flag')
  if (!Array.isArray(o.in) || o.in.length !== 3 || !o.in.every(isLevel)) {
    throw new InvalidIoStateError('in must be three 0/1 levels')
  }
  if (!Array.isArray(o.relay) || o.relay.length !== 2 || !o.relay.every(isLevel)) {
    throw new InvalidIoStateError('relay must be two 0/1 states')
  }

  const state: IoState = {
    active: o.active,
    left: typeof o.left === 'number' && Number.isFinite(o.left) && o.left > 0 ? Math.floor(o.left) : 0,
    in: o.in as number[],
    relay: o.relay as number[],
  }

  if (typeof o.ntc === 'number' && Number.isFinite(o.ntc)) state.ntc = o.ntc

  if (o.ow !== undefined) {
    if (!Array.isArray(o.ow) || o.ow.length !== 2 || !o.ow.every(Array.isArray)) {
      throw new InvalidIoStateError('ow must be two device lists')
    }
    state.ow = (o.ow as unknown[][]).map(bus => bus.map((d) => {
      const dev = d as Record<string, unknown>
      if (!dev || typeof dev.id !== 'string' || !/^[0-9A-F]{16}$/i.test(dev.id)) {
        throw new InvalidIoStateError('1-Wire device needs a 16-hex-digit id')
      }
      const out: OneWireDevice = { id: dev.id.toUpperCase() }
      if (typeof dev.t === 'number' && Number.isFinite(dev.t)) out.t = dev.t
      return out
    }))
  }

  return state
}
