/**
 * Temperature sensors of a machine's board: the onboard NTC (TH1) and the
 * DS18B20 probes on the WROOM-1U 1-Wire buses.
 *
 * Readings: the firmware adds the latest ones to every `/mdb-log` snapshot,
 * stored by mqtt-webhook in `embeddeds.mdb_diagnostics.temps`:
 *   {"ntc":41.3,"ow":[{"id":"28FF64A1B2C30405","b":1,"t":21.5}]}
 * While an I/O test runs, `embeddeds.io_state` carries fresher ones.
 *
 * Settings: `vendingMachine.temp_sensors` holds the operator's name for each
 * sensor and whether it is shown next to the machine name (machine page and
 * Machines panel): [{"id":"ntc","name":"PCB","show":true}, ...].
 */

/** Id of the onboard thermistor in settings and readings. */
export const NTC_SENSOR_ID = 'ntc'

/**
 * Readings are refreshed every 5 min and sent with the 5-min heartbeat, so
 * one older than this means the board stopped reporting.
 */
export const TEMPS_STALE_MS = 20 * 60 * 1000

export interface TempSensorSetting {
  /** "ntc" or a 1-Wire ROM id (16 hex digits). */
  id: string
  name: string
  show: boolean
}

export interface TempReading {
  id: string
  /** 1-Wire bus (1 or 2); missing for the NTC. */
  bus?: number
  celsius: number
}

export interface KnownSensor extends TempSensorSetting {
  reading: TempReading | null
}

export interface ShownTemperature {
  id: string
  label: string
  celsius: number | null
}

export const MAX_SENSOR_NAME_LENGTH = 40

function isFiniteNumber(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v)
}

function normaliseId(id: unknown): string | null {
  if (typeof id !== 'string') return null
  const trimmed = id.trim()
  if (!trimmed) return null
  return trimmed.toLowerCase() === NTC_SENSOR_ID ? NTC_SENSOR_ID : trimmed.toUpperCase()
}

/** `vendingMachine.temp_sensors` → clean settings (bad entries dropped, ids deduplicated). */
export function parseTempSettings(raw: unknown): TempSensorSetting[] {
  if (!Array.isArray(raw)) return []
  const seen = new Set<string>()
  const out: TempSensorSetting[] = []
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') continue
    const e = entry as Record<string, unknown>
    const id = normaliseId(e.id)
    if (!id || seen.has(id)) continue
    seen.add(id)
    out.push({
      id,
      name: typeof e.name === 'string' ? e.name.trim().slice(0, MAX_SENSOR_NAME_LENGTH) : '',
      show: e.show === true,
    })
  }
  return out
}

/** Settings as they should be saved: names trimmed, entries that say nothing dropped. */
export function cleanTempSettings(settings: TempSensorSetting[]): TempSensorSetting[] {
  return parseTempSettings(settings).filter(s => s.name !== '' || s.show)
}

/** Readings from `embeddeds.mdb_diagnostics` (its `temps` block). */
export function readingsFromDiagnostics(diagnostics: unknown): TempReading[] {
  const temps = (diagnostics as { temps?: unknown } | null | undefined)?.temps as
    { ntc?: unknown; ow?: unknown } | undefined
  if (!temps || typeof temps !== 'object') return []
  const out: TempReading[] = []
  if (isFiniteNumber(temps.ntc)) out.push({ id: NTC_SENSOR_ID, celsius: temps.ntc })
  if (Array.isArray(temps.ow)) {
    for (const p of temps.ow as { id?: unknown; b?: unknown; t?: unknown }[]) {
      const id = normaliseId(p?.id)
      if (!id || id === NTC_SENSOR_ID || !isFiniteNumber(p.t)) continue
      out.push({ id, celsius: p.t, ...(isFiniteNumber(p.b) ? { bus: p.b } : {}) })
    }
  }
  return out
}

/** Readings from an I/O test snapshot (`embeddeds.io_state`). */
export function readingsFromIoState(ioState: unknown): TempReading[] {
  const s = ioState as { ntc?: unknown; ow?: unknown } | null | undefined
  if (!s || typeof s !== 'object') return []
  const out: TempReading[] = []
  if (isFiniteNumber(s.ntc)) out.push({ id: NTC_SENSOR_ID, celsius: s.ntc })
  if (Array.isArray(s.ow)) {
    s.ow.forEach((bus: unknown, b: number) => {
      if (!Array.isArray(bus)) return
      for (const p of bus as { id?: unknown; t?: unknown }[]) {
        const id = normaliseId(p?.id)
        if (!id || id === NTC_SENSOR_ID || !isFiniteNumber(p.t)) continue
        out.push({ id, bus: b + 1, celsius: p.t })
      }
    })
  }
  return out
}

/** Several reading lists into one, by id; the first list that has a sensor wins. */
export function mergeReadings(...lists: TempReading[][]): TempReading[] {
  const byId = new Map<string, TempReading>()
  for (const list of lists) {
    for (const r of list) if (!byId.has(r.id)) byId.set(r.id, r)
  }
  return [...byId.values()]
}

/**
 * Every sensor worth listing in the settings: the NTC first, then the named
 * ones in their saved order, then probes reported but not configured yet.
 */
export function knownSensors(settings: TempSensorSetting[], readings: TempReading[]): KnownSensor[] {
  const readingById = new Map(readings.map(r => [r.id, r]))
  const settingById = new Map(settings.map(s => [s.id, s]))
  const ids: string[] = []
  const add = (id: string) => { if (!ids.includes(id)) ids.push(id) }
  if (settingById.has(NTC_SENSOR_ID) || readingById.has(NTC_SENSOR_ID)) add(NTC_SENSOR_ID)
  settings.forEach(s => add(s.id))
  readings.forEach(r => add(r.id))
  return ids.map((id) => {
    const s = settingById.get(id)
    return { id, name: s?.name ?? '', show: s?.show ?? false, reading: readingById.get(id) ?? null }
  })
}

/** Settings with one sensor's name/visibility changed (added when missing). */
export function upsertTempSetting(
  settings: TempSensorSetting[],
  id: string,
  patch: Partial<Omit<TempSensorSetting, 'id'>>,
): TempSensorSetting[] {
  const i = settings.findIndex(s => s.id === id)
  if (i === -1) return [...settings, { id, name: '', show: false, ...patch }]
  return settings.map((s, j) => (j === i ? { ...s, ...patch } : s))
}

/** The distinctive part of a DS18B20 ROM id: the serial's low bytes ("…CA1462"). */
export function shortProbeId(id: string): string {
  return /^[0-9A-F]{16}$/i.test(id) ? id.slice(8, 14) : id
}

/** Name to show: the operator's, else a default ("PCB" for the NTC, the short ROM id for a probe). */
export function sensorLabel(id: string, name: string | undefined, ntcDefault: string): string {
  if (name && name.trim()) return name.trim()
  return id === NTC_SENSOR_ID ? ntcDefault : `#${shortProbeId(id)}`
}

/** The sensors picked for display, with their latest reading (null when not reported). */
export function shownTemperatures(
  settings: TempSensorSetting[],
  readings: TempReading[],
  ntcDefault: string,
): ShownTemperature[] {
  const readingById = new Map(readings.map(r => [r.id, r]))
  return settings
    .filter(s => s.show)
    .map(s => ({
      id: s.id,
      label: sensorLabel(s.id, s.name, ntcDefault),
      celsius: readingById.get(s.id)?.celsius ?? null,
    }))
}

/** True when the diagnostics snapshot is too old to trust its temperatures. */
export function isTempsStale(diagnostics: unknown, now: number): boolean {
  const at = (diagnostics as { updated_at?: unknown } | null | undefined)?.updated_at
  if (typeof at !== 'string') return true
  const ms = Date.parse(at)
  return Number.isNaN(ms) || now - ms > TEMPS_STALE_MS
}

export function formatCelsius(c: number | null | undefined): string {
  return c === null || c === undefined ? '–' : `${c.toFixed(1)} °C`
}
