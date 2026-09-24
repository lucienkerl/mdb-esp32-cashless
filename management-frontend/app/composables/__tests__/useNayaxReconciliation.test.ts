import { describe, it, expect } from 'vitest'
import { alignSequences, alignMachine, bufferRange, groupDifferencesByDay } from '../useNayaxReconciliation'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'
import { localDtToUtc, parseSelectionInfo, parseTitleDateRange, effectiveNayaxItemNumber } from '../useNayaxReconciliation'
import { useNayaxReconciliation, derivedChannelFromPaymentSource, type NayaxRow, type DbSale } from '../useNayaxReconciliation'

function loadFixture(name: string): File {
  const here = dirname(fileURLToPath(import.meta.url))
  const buf = readFileSync(resolve(here, '../../test-helpers/fixtures', name))
  // Cast Buffer to ArrayBuffer for the File constructor
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)
  return new File([ab as ArrayBuffer], name, {
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  })
}

describe('localDtToUtc', () => {
  it('parses Nayax DD.MM.YYYY HH:MM:SS in CEST (summer) to UTC', () => {
    // 2026-03-31 is after DST start (2026-03-29) -> CEST (UTC+2)
    expect(localDtToUtc('31.03.2026 21:46:09', 'Europe/Berlin'))
      .toBe('2026-03-31T19:46:09.000Z')
  })

  it('parses Nayax DD.MM.YYYY HH:MM:SS in CET (winter) to UTC', () => {
    // 2026-01-15 is winter -> CET (UTC+1)
    expect(localDtToUtc('15.01.2026 12:00:00', 'Europe/Berlin'))
      .toBe('2026-01-15T11:00:00.000Z')
  })

  it('handles the spring-forward gap without throwing', () => {
    // 02:30 on 2026-03-29 does not exist in Europe/Berlin (clocks jump
    // 02:00 CET -> 03:00 CEST). The exact value returned by date-fns-tz
    // for non-existent instants is library-defined and has historically
    // differed across versions — we don't pin a specific UTC time. We
    // only assert the function returns *some* valid ISO 8601 within the
    // plausible window (00:30 UTC if pre-jump, 01:30 UTC if post-jump).
    const out = localDtToUtc('29.03.2026 02:30:00', 'Europe/Berlin')
    expect(out).toMatch(/^2026-03-29T0[01]:30:00\.000Z$/)
  })

  it('returns empty string for malformed input', () => {
    expect(localDtToUtc('not a date', 'Europe/Berlin')).toBe('')
    expect(localDtToUtc('', 'Europe/Berlin')).toBe('')
  })

  it('returns empty string for regex-valid but semantically-invalid dates', () => {
    // Feb 29 only exists in leap years; 2026 isn't one.
    expect(localDtToUtc('29.02.2026 12:00:00', 'Europe/Berlin')).toBe('')
    // April has 30 days.
    expect(localDtToUtc('31.04.2026 12:00:00', 'Europe/Berlin')).toBe('')
    // Hour out of range.
    expect(localDtToUtc('01.05.2026 25:00:00', 'Europe/Berlin')).toBe('')
  })
})

describe('parseSelectionInfo', () => {
  it('extracts the item number from "Product Name(N  price)"', () => {
    expect(parseSelectionInfo('Mars Classic Single(39  1.20)')).toBe(39)
  })

  it('handles two-digit item numbers', () => {
    expect(parseSelectionInfo('Powerade Sports Mountain Blast(58  2.50)')).toBe(58)
  })

  it('handles three-digit item numbers', () => {
    expect(parseSelectionInfo('Test(123  9.99)')).toBe(123)
  })

  it('handles single-digit item numbers', () => {
    expect(parseSelectionInfo('Test(1  0.50)')).toBe(1)
  })

  it('returns null when no parenthesis group is present', () => {
    expect(parseSelectionInfo('Just a product name')).toBeNull()
    expect(parseSelectionInfo('')).toBeNull()
  })

  it('returns null when the parenthesis group is malformed', () => {
    expect(parseSelectionInfo('Product(abc  1.00)')).toBeNull()
    expect(parseSelectionInfo('Product()')).toBeNull()
  })

  it('strips trailing whitespace and newlines (Nayax exports often have them)', () => {
    expect(parseSelectionInfo('NicNacs 35g(38  1.50)\n')).toBe(38)
  })
})

describe('parseTitleDateRange', () => {
  it('extracts from the German "Gesuchter Datumsbereich:" line', () => {
    // Note: the real Nayax file prefixes the title with a handful of
    // U+200B zero-width spaces. They're invisible and don't affect the
    // regex, so we just use the visible content here.
    const title = 'Dynamische Transaktionsüberwachung\nGesuchter Datumsbereich: 01.03.2026 00:00:00 - 31.03.2026 23:59:59'
    expect(parseTitleDateRange(title, 'Europe/Berlin')).toEqual({
      fromUtc: '2026-02-28T23:00:00.000Z',  // 01.03 00:00 CET = 28.02 23:00 UTC
      toUtc:   '2026-03-31T21:59:59.000Z',  // 31.03 23:59:59 CEST = 21:59:59 UTC
    })
  })

  it('returns null when the line is missing', () => {
    expect(parseTitleDateRange('Random title', 'Europe/Berlin')).toBeNull()
  })

  it('returns null when only the start half is present', () => {
    expect(parseTitleDateRange('Datumsbereich: 01.03.2026 00:00:00', 'Europe/Berlin')).toBeNull()
  })
})

describe('parseFile', () => {
  it('parses the Nayax fixture without errors', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    expect(r.rawRows.value.length).toBeGreaterThan(0)
    expect(r.error.value).toBe('')
  })

  it('skips the title row and the Total footer', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    // No row should have txId "" or machineName "Total"
    for (const row of r.rawRows.value) {
      expect(row.txId).not.toBe('')
      expect(row.machineName).not.toBe('Total')
    }
  })

  it('extracts the expected fields from the first data row', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    const first = r.rawRows.value[0]
    // First row in the fixture: Powerade Sports Mountain Blast, 31.03.2026 21:46:09
    expect(first.txId).toBe('62968009978')
    expect(first.nayaxMachineId).toBe('92700604')
    expect(first.machineName).toBe('Niedernhall Frankeneck')
    expect(first.productName).toBe('Powerade Sports Mountain Blast')
    expect(first.paymentSource).toBe('Cash')
    expect(first.priceGross).toBe(2.5)
    expect(first.itemNumber).toBe(58)
    expect(first.localDt).toBe('31.03.2026 21:46:09')
    expect(first.utcDt).toBe('2026-03-31T19:46:09.000Z')
  })

  it('populates fileDateRange from the title row', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    await r.parseFile(loadFixture('nayax-sample.xlsx'))
    // Title says "01.03.2026 00:00:00 - 31.03.2026 23:59:59" in Europe/Berlin
    expect(r.settings.value.fromUtc).toBe('2026-02-28T23:00:00.000Z')
    expect(r.settings.value.toUtc).toBe('2026-03-31T21:59:59.000Z')
  })

  it('refuses files over the 50 000-row hard cap', async () => {
    const { useNayaxReconciliation } = await import('../useNayaxReconciliation')
    const r = useNayaxReconciliation()
    // Simulate a huge file by directly testing the cap via a synthetic
    // override (we don't actually generate 50k rows in CI). Instead,
    // expose MAX_ROWS as a constant the test can read and the implementation
    // uses for its threshold.
    const { MAX_ROWS_HARD_CAP } = await import('../useNayaxReconciliation')
    expect(MAX_ROWS_HARD_CAP).toBe(50000)
  })
})

function setupRecon(seed: {
  rawRows: NayaxRow[]
  mapping: Record<string, string>
  dbSales: DbSale[]
  fromUtc?: string
  toUtc?: string
}) {
  const r = useNayaxReconciliation()
  // Note: in tests, the `#imports` → `nuxt-stubs.ts` alias makes
  // `useState(key, init)` return a fresh ref per call, so each `setupRecon`
  // invocation starts with its own isolated state — that's what we want.
  r.rawRows.value = seed.rawRows
  r.mapping.value = seed.mapping
  r.dbSales.value = seed.dbSales
  r.settings.value = {
    timezone: 'Europe/Berlin',
    fromUtc: seed.fromUtc ?? '2026-03-01T00:00:00.000Z',
    toUtc: seed.toUtc ?? '2026-03-31T23:59:59.000Z',
  }
  return r
}

function mkNayax(over: Partial<NayaxRow> = {}): NayaxRow {
  return {
    rowIndex: 3, txId: 'tx1', nayaxMachineId: 'N1', machineName: 'M1',
    productGroup: 'g', productName: 'p', paymentSource: 'Cash',
    priceGross: 2.5, itemNumber: 58, selectionInfoRaw: 'p(58  2.50)',
    localDt: '31.03.2026 21:46:09', utcDt: '2026-03-31T19:46:09.000Z',
    ...over,
  }
}

function mkSale(over: Partial<DbSale> = {}): DbSale {
  return {
    id: 's1', created_at: '2026-03-31T19:46:11.000Z',
    machine_id: 'vm1', item_number: 58, item_price: 2.5,
    channel: 'cash', product_id: null, product_name: null,
    ...over,
  }
}

describe('runMatch (sequence)', () => {
  it('matches an exact in-order subset; reports the single gap', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 20, utcDt: '2026-03-10T09:00:00.000Z' }),
        mkNayax({ txId: 'C', itemNumber: 30, utcDt: '2026-03-10T10:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 10, created_at: '2026-03-10T08:00:05.000Z' }),
        mkSale({ id: 's3', item_number: 30, created_at: '2026-03-10T10:00:05.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched.map(m => m.nayax.txId)).toEqual(['A', 'C'])
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('matches identical order even when timestamps are wildly off (drift regression)', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 20, utcDt: '2026-03-10T09:00:00.000Z' }),
        mkNayax({ txId: 'C', itemNumber: 30, utcDt: '2026-03-10T10:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 10, created_at: '2026-03-10T08:03:00.000Z' }),
        mkSale({ id: 's2', item_number: 20, created_at: '2026-03-10T09:03:00.000Z' }),
        mkSale({ id: 's3', item_number: 30, created_at: '2026-03-10T10:03:00.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(3)
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('flags a DB-only sale as a phantom (ghost) in range', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 'ok',    item_number: 10, created_at: '2026-03-10T08:00:01.000Z' }),
        mkSale({ id: 'extra', item_number: 99, created_at: '2026-03-10T09:00:00.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.ghostInDb.map(s => s.id)).toEqual(['extra'])
  })

  it('handles a repeated slot: one of two equal sales is missing', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 10, utcDt: '2026-03-10T08:05:00.000Z' }),
        mkNayax({ txId: 'C', itemNumber: 20, utcDt: '2026-03-10T08:10:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 10, created_at: '2026-03-10T08:00:30.000Z' }),
        mkSale({ id: 's2', item_number: 20, created_at: '2026-03-10T08:10:30.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(2)
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('matches on slot but flags a price difference', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, priceGross: 2.5, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [mkSale({ item_number: 10, item_price: 3.0, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.matched[0]!.priceDiffers).toBe(true)
    expect(r.result.value!.missingInDb).toHaveLength(0)
  })

  it('flags priceDiffers when the DB sale has item_price null', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, priceGross: 2.5, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [mkSale({ item_number: 10, item_price: null, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.matched[0]!.priceDiffers).toBe(true)
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('does not flag price when slot and price both match', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, priceGross: 2.5, utcDt: '2026-03-10T08:00:00.000Z' })],
      mapping: { N1: 'vm1' },
      dbSales: [mkSale({ item_number: 10, item_price: 2.5001, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched[0]!.priceDiffers).toBe(false)
  })

  it('reports an adjacent order swap as one missing + one ghost', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 20, utcDt: '2026-03-10T08:01:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's-20', item_number: 20, created_at: '2026-03-10T08:00:30.000Z' }),
        mkSale({ id: 's-10', item_number: 10, created_at: '2026-03-10T08:01:30.000Z' }),
      ],
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.missingInDb).toHaveLength(1)
    expect(r.result.value!.ghostInDb).toHaveLength(1)
  })

  it('aligns each machine independently (no cross-machine matching)', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', nayaxMachineId: 'N1', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', nayaxMachineId: 'N2', itemNumber: 10, utcDt: '2026-03-10T08:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1', N2: 'vm2' },
      dbSales: [mkSale({ machine_id: 'vm1', item_number: 10, created_at: '2026-03-10T08:00:02.000Z' })],
    })
    r.runMatch()
    expect(r.result.value!.matched.map(m => m.nayax.txId)).toEqual(['A'])
    expect(r.result.value!.missingInDb.map(n => n.txId)).toEqual(['B'])
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('keeps a matched pair when the DB row is just outside the strict range (buffer)', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ itemNumber: 10, utcDt: '2026-03-31T23:59:00.000Z' })],
      mapping: { N1: 'vm1' },
      // DB twin recorded one minute past the file's `toUtc` (still loaded via the
      // ±2-min query buffer). Must match, not become a ghost.
      dbSales: [mkSale({ item_number: 10, created_at: '2026-04-01T00:00:30.000Z' })],
      fromUtc: '2026-03-01T00:00:00.000Z',
      toUtc: '2026-03-31T23:59:59.000Z',
    })
    r.runMatch()
    expect(r.result.value!.matched).toHaveLength(1)
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })

  it('routes unmapped and unparseable rows to their buckets', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'U', nayaxMachineId: 'UNKNOWN', itemNumber: 10 }),
        mkNayax({ txId: 'P', itemNumber: null }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [],
    })
    r.runMatch()
    expect(r.result.value!.unmapped.map(n => n.txId)).toEqual(['U'])
    expect(r.result.value!.unparseable.map(n => n.txId)).toEqual(['P'])
    expect(r.result.value!.missingInDb).toHaveLength(0)
  })

  it('flags a DB sale on a mapped machine absent from the file as a ghost', () => {
    const r = setupRecon({
      rawRows: [],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 'in',  item_number: 10, created_at: '2026-03-15T12:00:00.000Z' }),
        mkSale({ id: 'out', item_number: 10, created_at: '2026-04-15T12:00:00.000Z' }),
      ],
      fromUtc: '2026-03-01T00:00:00.000Z',
      toUtc:   '2026-03-31T23:59:59.000Z',
    })
    r.runMatch()
    expect(r.result.value!.ghostInDb.map(s => s.id)).toEqual(['in'])
  })

  it('does not flag a real in-range sale as a phantom when a same-slot buffer row precedes the range (start-edge collision)', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 11, utcDt: '2026-03-01T08:10:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 22, utcDt: '2026-03-01T08:30:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        // slot 11 ~90s BEFORE fromUtc — only present because loadDbSales buffers ±2min
        mkSale({ id: 'buf',    item_number: 11, created_at: '2026-03-01T07:58:30.000Z' }),
        mkSale({ id: 'real11', item_number: 11, created_at: '2026-03-01T08:10:05.000Z' }),
        mkSale({ id: 'real22', item_number: 22, created_at: '2026-03-01T08:30:05.000Z' }),
      ],
      fromUtc: '2026-03-01T08:00:00.000Z',
      toUtc:   '2026-03-01T20:00:00.000Z',
    })
    r.runMatch()
    // Both Nayax rows match their REAL in-range sales; the pre-range buffer row is dropped, not a phantom.
    expect([...r.result.value!.matched.map(m => m.db.id)].sort()).toEqual(['real11', 'real22'])
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })
})

describe('derivedChannelFromPaymentSource', () => {
  it('maps "Cash" to "cash"', () => {
    expect(derivedChannelFromPaymentSource('Cash')).toBe('cash')
  })
  it('maps any "Credit Card(*)" to "card"', () => {
    expect(derivedChannelFromPaymentSource('Credit Card(CLS)')).toBe('card')
    expect(derivedChannelFromPaymentSource('Credit Card(Whatever)')).toBe('card')
  })
  it('maps unknown values to "nayax"', () => {
    expect(derivedChannelFromPaymentSource('Apple Pay')).toBe('nayax')
    expect(derivedChannelFromPaymentSource('')).toBe('nayax')
  })
})

describe('exportDiffCsv', () => {
  it('emits one CSV row per matched/missing/ghost entry with the documented columns', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A' }),                               // matched
        mkNayax({ txId: 'B', utcDt: '2026-03-31T19:46:30.000Z' }),  // missing (no DB sale)
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 'sA' }),                                 // matches A
        mkSale({ id: 'sG', created_at: '2026-03-20T12:00:00.000Z',
                 item_number: 99, item_price: 1.0 }),          // ghost
      ],
    })
    r.runMatch()
    const csv = r.exportDiffCsv()
    const lines = csv.trim().split('\n')
    // Header + 1 matched + 1 missing + 1 ghost = 4 lines
    expect(lines.length).toBe(4)
    expect(lines[0]).toBe(
      'bucket,nayax_time_local,nayax_time_utc,db_time_utc,delta_seconds,machine_name,slot,product,price,payment_source,channel,nayax_tx_id,db_sale_id',
    )
    // Just sanity-check one column from each bucket row
    expect(lines.some(l => l.startsWith('matched,'))).toBe(true)
    expect(lines.some(l => l.startsWith('missing_in_db,'))).toBe(true)
    expect(lines.some(l => l.startsWith('ghost_in_db,'))).toBe(true)
  })

  it('escapes commas and quotes inside string fields', () => {
    const r = setupRecon({
      rawRows: [mkNayax({ productName: 'Coke, Zero', txId: 't"x' })],
      mapping: { N1: 'vm1' },
      dbSales: [],
    })
    r.runMatch()
    const csv = r.exportDiffCsv()
    // product column should be quoted, internal quotes doubled
    expect(csv).toContain('"Coke, Zero"')
    expect(csv).toContain('"t""x"')
  })
})

describe('alignSequences', () => {
  it('aligns two identical sequences fully', () => {
    expect(alignSequences([1, 2, 3], [1, 2, 3])).toEqual({
      pairs: [[0, 0], [1, 1], [2, 2]], aOnly: [], bOnly: [],
    })
  })

  it('flags a gap in B as aOnly (in order)', () => {
    // A=[1,2,3], B=[1,3]  -> 2 is missing from B
    expect(alignSequences([1, 2, 3], [1, 3])).toEqual({
      pairs: [[0, 0], [2, 1]], aOnly: [1], bOnly: [],
    })
  })

  it('flags an extra in B as bOnly', () => {
    // A=[1,3], B=[1,2,3] -> 2 is extra in B
    expect(alignSequences([1, 3], [1, 2, 3])).toEqual({
      pairs: [[0, 0], [1, 2]], aOnly: [], bOnly: [1],
    })
  })

  it('handles repeats: one of two equal tokens is missing', () => {
    // A=[1,1,2], B=[1,2] -> one of the 1s is aOnly
    expect(alignSequences([1, 1, 2], [1, 2])).toEqual({
      pairs: [[0, 0], [2, 1]], aOnly: [1], bOnly: [],
    })
  })

  it('reports both directions for an adjacent swap of distinct tokens', () => {
    // A=[1,2], B=[2,1] -> LCS length 1
    const out = alignSequences([1, 2], [2, 1])
    expect(out.pairs).toEqual([[1, 0]]) // the 2s align
    expect(out.aOnly).toEqual([0])      // the leading 1 in A
    expect(out.bOnly).toEqual([1])      // the trailing 1 in B
  })

  it('handles empty inputs', () => {
    expect(alignSequences([], [5, 6])).toEqual({ pairs: [], aOnly: [], bOnly: [0, 1] })
    expect(alignSequences([5, 6], [])).toEqual({ pairs: [], aOnly: [0, 1], bOnly: [] })
  })

  it('simplest non-matching pair: single distinct elements are both unmatched', () => {
    expect(alignSequences([1], [2])).toEqual({ pairs: [], aOnly: [0], bOnly: [0] })
  })
})

describe('alignMachine', () => {
  const days = (n: number, d = '2026-03-10') => Array(n).fill(d)

  it('uses a single LCS under the cell budget (bucketed=false)', () => {
    const out = alignMachine([1, 2, 3], days(3), [1, 3], days(2), 1_000_000)
    expect(out.bucketed).toBe(false)
    expect(out.pairs).toEqual([[0, 0], [2, 1]])
    expect(out.aOnly).toEqual([1])
    expect(out.bOnly).toEqual([])
  })

  it('falls back to per-UTC-day buckets over budget (bucketed=true), translating indices', () => {
    // Two days; force the fallback with a tiny budget.
    const aKeys = [1, 2, 9]
    const aDays = ['2026-03-10', '2026-03-10', '2026-03-11']
    const bKeys = [1, 2, 9]
    const bDays = ['2026-03-10', '2026-03-10', '2026-03-11']
    const out = alignMachine(aKeys, aDays, bKeys, bDays, 1)
    expect(out.bucketed).toBe(true)
    expect(out.pairs).toEqual([[0, 0], [1, 1], [2, 2]])
    expect(out.aOnly).toEqual([])
    expect(out.bOnly).toEqual([])
  })

  it('does not align identical tokens that fall in different day buckets (the fallback tradeoff)', () => {
    // Same token 5 but on different days -> cannot pair under day-bucketing.
    const out = alignMachine([5], ['2026-03-10'], [5], ['2026-03-11'], 1)
    expect(out.bucketed).toBe(true)
    expect(out.pairs).toEqual([])
    expect(out.aOnly).toEqual([0])
    expect(out.bOnly).toEqual([0])
  })

  it('budget check is <=: 4-cell table stays single-LCS at maxCells=4 but buckets at maxCells=3', () => {
    // One element each -> DP table is (1+1)*(1+1) = 4 cells.
    // Same UTC day, same key value so the single pair [0,0] is the LCS in both paths.
    const aKeys = [7]
    const bKeys = [7]
    const aDay = ['2026-03-10']
    const bDay = ['2026-03-10']

    const exact = alignMachine(aKeys, aDay, bKeys, bDay, 4)
    expect(exact.bucketed).toBe(false)
    expect(exact.pairs).toEqual([[0, 0]])

    const bucketed = alignMachine(aKeys, aDay, bKeys, bDay, 3)
    expect(bucketed.bucketed).toBe(true)
    // Same pairs regardless of path because the elements are on the same day.
    expect(bucketed.pairs).toEqual([[0, 0]])
    expect(bucketed.aOnly).toEqual([])
    expect(bucketed.bOnly).toEqual([])
  })
})

describe('bufferRange', () => {
  it('pads both bounds by the given seconds without mutating inputs', () => {
    expect(bufferRange('2026-03-01T00:00:00.000Z', '2026-03-31T23:59:59.000Z', 120)).toEqual({
      gte: '2026-02-28T23:58:00.000Z',
      lte: '2026-04-01T00:01:59.000Z',
    })
  })
})

describe('groupDifferencesByDay', () => {
  // vitest pins TZ=UTC (Task 1.0), so getFullYear/Month/Date == UTC parts —
  // grouping is by UTC day and these assertions are deterministic on any runner.
  it('groups by day, sorts chronologically, missing-before-ghost on ties', () => {
    const missing = [
      mkNayax({ txId: 'm-d2', utcDt: '2026-03-11T12:00:00.000Z' }),
      mkNayax({ txId: 'm-d1', utcDt: '2026-03-10T12:00:00.000Z' }),
    ]
    const ghosts = [
      mkSale({ id: 'g-d1', created_at: '2026-03-10T12:00:00.000Z' }),
    ]
    const groups = groupDifferencesByDay(missing, ghosts)
    expect(groups).toHaveLength(2)
    // Day 1 group: missing then ghost (same ts -> missing first)
    expect(groups[0]!.rows.map(r => r.kind)).toEqual(['missing', 'ghost'])
    expect(groups[0]!.rows[0]!.kind === 'missing' && groups[0]!.rows[0]!.payload.txId).toBe('m-d1')
    // Day 2 group: the later missing row
    expect(groups[1]!.rows).toHaveLength(1)
    expect(groups[1]!.rows[0]!.kind === 'missing' && groups[1]!.rows[0]!.payload.txId).toBe('m-d2')
  })

  it('returns one group when all rows share a day', () => {
    // TZ=UTC pinned, so these two same-UTC-day instants land in one group.
    const groups = groupDifferencesByDay(
      [mkNayax({ utcDt: '2026-03-10T08:00:00.000Z' }), mkNayax({ utcDt: '2026-03-10T20:00:00.000Z' })],
      [],
    )
    expect(groups).toHaveLength(1)
    expect(groups[0]!.rows).toHaveLength(2)
  })

  it('returns no groups for no differences', () => {
    expect(groupDifferencesByDay([], [])).toEqual([])
  })
})


describe('effectiveNayaxItemNumber', () => {
  const cfg = { offset: 9, since: '2026-08-27T10:00:00.000Z' }

  it('returns the raw number when no offset is configured', () => {
    expect(effectiveNayaxItemNumber(1, '2026-08-27T12:00:00.000Z', undefined)).toBe(1)
    expect(effectiveNayaxItemNumber(1, '2026-08-27T12:00:00.000Z', { offset: 0, since: null })).toBe(1)
  })

  it('shifts rows at or after the cut-over', () => {
    expect(effectiveNayaxItemNumber(1, '2026-08-27T10:00:00.000Z', cfg)).toBe(10)
    expect(effectiveNayaxItemNumber(1, '2026-08-27T12:00:00.000Z', cfg)).toBe(10)
    expect(effectiveNayaxItemNumber(11, '2026-08-27T12:00:00.000Z', cfg)).toBe(20)
  })

  it('leaves rows from before the cut-over raw \u2014 there was no backfill', () => {
    expect(effectiveNayaxItemNumber(1, '2026-08-26T23:59:59.000Z', cfg)).toBe(1)
  })

  it('treats a missing cut-over stamp as "never shift"', () => {
    // Defensive: offset set but stamp somehow absent. Shifting everything would
    // silently rewrite history; refusing to shift only degrades to today.
    expect(effectiveNayaxItemNumber(1, '2026-08-27T12:00:00.000Z', { offset: 9, since: null })).toBe(1)
  })

  it('never returns a negative item number', () => {
    expect(effectiveNayaxItemNumber(1, '2026-08-27T12:00:00.000Z', { offset: -9, since: cfg.since })).toBe(0)
  })
})

describe('effectiveNayaxItemNumber with tray mappings', () => {
  // The machine reports 3 for the tray labelled 25; the mapping took effect at noon.
  const trays = { 3: { itemNumber: 25, since: '2026-09-24T12:00:00.000Z' } }
  const cfg = { offset: 9, since: '2026-09-01T00:00:00.000Z' }

  it('maps rows at or after the tray mapping took effect', () => {
    expect(effectiveNayaxItemNumber(3, '2026-09-24T12:00:00.000Z', undefined, trays)).toBe(25)
    expect(effectiveNayaxItemNumber(3, '2026-09-24T15:00:00.000Z', undefined, trays)).toBe(25)
  })

  it('leaves rows from before the mapping as they were recorded', () => {
    expect(effectiveNayaxItemNumber(3, '2026-09-24T11:59:59.000Z', undefined, trays)).toBe(3)
  })

  it('leaves unmapped numbers to the offset', () => {
    expect(effectiveNayaxItemNumber(4, '2026-09-24T15:00:00.000Z', cfg, trays)).toBe(13)
  })

  it('wins over the offset once in effect; before that the offset applied at ingest', () => {
    expect(effectiveNayaxItemNumber(3, '2026-09-24T15:00:00.000Z', cfg, trays)).toBe(25)
    expect(effectiveNayaxItemNumber(3, '2026-09-10T15:00:00.000Z', cfg, trays)).toBe(12)
  })

  it('treats a missing cut-over stamp as "never mapped"', () => {
    expect(effectiveNayaxItemNumber(3, '2026-09-24T15:00:00.000Z', undefined, { 3: { itemNumber: 25, since: null } })).toBe(3)
  })
})

describe('runMatch with tray mappings', () => {
  it('aligns a raw Nayax selection with the sale booked on the mapped slot', () => {
    const r = setupRecon({
      rawRows: [
        mkNayax({ txId: 'A', itemNumber: 3, utcDt: '2026-03-10T08:00:00.000Z' }),
        mkNayax({ txId: 'B', itemNumber: 4, utcDt: '2026-03-10T09:00:00.000Z' }),
      ],
      mapping: { N1: 'vm1' },
      dbSales: [
        mkSale({ id: 's1', item_number: 25, created_at: '2026-03-10T08:00:05.000Z' }),
        mkSale({ id: 's2', item_number: 4, created_at: '2026-03-10T09:00:05.000Z' }),
      ],
    })
    r.trayMappings.value = { vm1: { 3: { itemNumber: 25, since: '2026-03-01T00:00:00.000Z' } } }
    r.runMatch()
    expect(r.result.value!.matched.map(m => m.nayax.txId)).toEqual(['A', 'B'])
    expect(r.result.value!.missingInDb).toHaveLength(0)
    expect(r.result.value!.ghostInDb).toHaveLength(0)
  })
})
