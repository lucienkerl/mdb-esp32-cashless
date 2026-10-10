/**
 * Parsing and validation of the firmware's `/mdb-trace` batches.
 *
 * Wire format (plain JSON, see mdb-slave-esp32s3/main/mdb_trace.h):
 *
 *   {"drop":0,"f":[[12,"t","10B"],[9,"r","1120"],...]}
 *
 *   f[i] = [age_ms, dir, words]
 *     age_ms : ms between the frame's first word and the moment the batch was built
 *     dir    : "r" seen on the bus, "t" transmitted by the device
 *     words  : concatenated 3-digit upper-case hex, one per 9-bit MDB word
 *
 * The payload comes straight off the broker, so it is validated rather than
 * trusted: a malformed batch must never reach the table the console renders.
 */

export type TraceDir = 'r' | 't'
export type TraceFrame = [ageMs: number, dir: TraceDir, words: string]

export interface MdbTraceBatch {
  dropped: number
  frames: TraceFrame[]
}

/** Firmware batches are < 1.5 KB; anything past this is not ours. */
export const MAX_FRAMES_PER_BATCH = 200
/** Longest MDB block (36 bytes incl. checksum), 3 hex digits each. */
export const MAX_WORDS_PER_FRAME = 36
/** The firmware's age is a uint32 of milliseconds; a day is already absurd. */
export const MAX_AGE_MS = 24 * 60 * 60 * 1000

export class InvalidTraceError extends Error {}

export function parseMdbTrace(rawJson: string): MdbTraceBatch {
  let data: unknown
  try {
    data = JSON.parse(rawJson)
  } catch {
    throw new InvalidTraceError('invalid JSON in mdb-trace payload')
  }

  if (typeof data !== 'object' || data === null) {
    throw new InvalidTraceError('mdb-trace payload must be an object')
  }
  const { drop, f } = data as { drop?: unknown; f?: unknown }

  if (!Array.isArray(f)) throw new InvalidTraceError('missing frames array "f"')
  if (f.length === 0) throw new InvalidTraceError('empty frames array')
  if (f.length > MAX_FRAMES_PER_BATCH) throw new InvalidTraceError('too many frames in batch')

  let dropped = 0
  if (drop !== undefined) {
    if (typeof drop !== 'number' || !Number.isInteger(drop) || drop < 0) {
      throw new InvalidTraceError('"drop" must be a non-negative integer')
    }
    dropped = drop
  }

  const frames: TraceFrame[] = f.map((entry: unknown, i: number) => {
    if (!Array.isArray(entry) || entry.length !== 3) {
      throw new InvalidTraceError(`frame ${i} must be [age_ms, dir, words]`)
    }
    const [age, dir, words] = entry
    if (typeof age !== 'number' || !Number.isInteger(age) || age < 0 || age > MAX_AGE_MS) {
      throw new InvalidTraceError(`frame ${i}: bad age_ms`)
    }
    if (dir !== 'r' && dir !== 't') {
      throw new InvalidTraceError(`frame ${i}: dir must be "r" or "t"`)
    }
    if (typeof words !== 'string' || words.length === 0 || words.length % 3 !== 0 ||
        words.length > MAX_WORDS_PER_FRAME * 3 || !/^[0-9A-F]+$/.test(words)) {
      throw new InvalidTraceError(`frame ${i}: words must be 3-digit upper-case hex`)
    }
    // A 9-bit word never exceeds 0x1FF.
    for (let k = 0; k < words.length; k += 3) {
      if (parseInt(words.slice(k, k + 3), 16) > 0x1ff) {
        throw new InvalidTraceError(`frame ${i}: word above 9 bits`)
      }
    }
    return [age, dir, words]
  })

  return { dropped, frames }
}

/** Rows older than this are pruned: a trace is live debugging, not history. */
export const TRACE_RETENTION_MS = 60 * 60 * 1000

/** Prune on roughly one batch in this many, so tracing costs no extra query per batch. */
export const PRUNE_EVERY_N_BATCHES = 20
