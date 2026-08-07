// ── Interfaces ──────────────────────────────────────────────────────────────

export interface CashBook {
  id: string
  created_at: string
  company_id: string
  name: string
  initial_balance: number
  bank_deposit_threshold: number
  track_per_machine: boolean
  activated_at: string
  created_by: string
  is_active: boolean
}

export interface BarkasseSettings {
  bank_deposit_threshold?: number
  track_per_machine?: boolean
}

export interface CashBookEntry {
  id: string
  created_at: string
  cash_book_id: string
  company_id: string
  entry_number: number
  type: 'initial' | 'withdrawal' | 'correction' | 'payout' | 'expense' | 'change_float' | 'reversal'
  amount: number
  balance_after: number
  description: string | null
  machine_id: string | null
  counted_amount: number | null
  expected_amount: number | null
  category: string | null
  receipt_reference: string | null
  corrects_entry_id: string | null
  paired_entry_id: string | null
  is_reversed: boolean
  created_by: string
  hash: string
  // Enriched client-side
  user_display?: string
}

export interface TheoreticalCash {
  theoretical_balance: number
  last_entry_balance: number
  cash_sales_since: number
  last_entry_at: string
  entry_count: number
  machines: { machine_id: string; machine_name: string; cash_sales: number }[]
}

export interface VendingMachineBasic {
  id: string
  name: string | null
  cash_book_id: string | null
}

// ── Expense categories (fixed list; labels via i18n) ─────────────────────────

export const EXPENSE_CATEGORIES = ['rent', 'goods', 'cleaning', 'fees', 'other'] as const
export type ExpenseCategory = typeof EXPENSE_CATEGORIES[number]

// ── Wechselgeld in Automaten (change_float) ─────────────────────────────────

/** Richtung einer Wechselgeldbuchung aus Sicht der Barkasse. */
export type ChangeFloatDirection = 'into_machine' | 'back_to_box'

/** Eine Zeile aus `get_machine_change_float` — vorgestrecktes Wechselgeld
 *  je (Automat, Barkasse). */
export interface MachineChangeFloat {
  machine_id: string
  machine_name: string | null
  cash_book_id: string
  float_balance: number
  last_change_at: string
}

/** Rechnet Richtung + nicht-negative Eingabe in den signierten `amount` um,
 *  der auf dem Eintrag landet. `amount` ist die Wirkung auf die Barkasse:
 *  Einlage in den Automaten senkt sie, Rücknahme hebt sie. Das Vorzeichen
 *  der Eingabe wird bewusst ignoriert — die Richtung entscheidet. */
export function changeFloatAmount(direction: ChangeFloatDirection, input: number): number {
  const abs = Math.abs(input)
  const signed = direction === 'into_machine' ? -abs : abs
  // -0 normalisieren: Intl.NumberFormat würde daraus "-0,00 €" machen.
  // Bewusst `=== 0` statt `|| 0` — das lässt NaN durch, statt einen
  // ungültigen Betrag in eine gültig aussehende Nullbuchung zu verwandeln.
  return signed === 0 ? 0 : signed
}

/** Vorgestrecktes Wechselgeld eines Automaten, summiert über Barkassen.
 *  Ein Automat kann die Barkasse gewechselt haben und dann mehrere Zeilen
 *  tragen. */
export function floatBalanceForMachine(rows: MachineChangeFloat[], machineId: string): number {
  return rows
    .filter(r => r.machine_id === machineId)
    .reduce((sum, r) => sum + r.float_balance, 0)
}

/** Gesamtes vorgestrecktes Wechselgeld über alle Zeilen. */
export function totalChangeFloat(rows: MachineChangeFloat[]): number {
  return rows.reduce((sum, r) => sum + r.float_balance, 0)
}

// ── User name cache (shared across instances) ──────────────────────────────

const userCache = new Map<string, string>()

// ── Composable ─────────────────────────────────────────────────────────────

export function useCashBook() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  // ── Reactive state ───────────────────────────────────────────────────────

  const cashBooks = ref<CashBook[]>([])
  const selectedCashBook = ref<CashBook | null>(null)
  const entries = ref<CashBookEntry[]>([])
  const theoreticalCash = ref<TheoreticalCash | null>(null)
  const changeFloat = ref<MachineChangeFloat[]>([])
  /** True, wenn der Wechselgeldbestand nicht geladen werden konnte (kein Mitglied
   *  dieser Firma, RPC-Fehler oder NULL). Ohne dieses Flag wäre der Fall von
   *  "kein Wechselgeld vorgestreckt" ([]) nicht zu unterscheiden — siehe
   *  fetchChangeFloat. */
  const changeFloatUnavailable = ref(false)
  const loading = ref(false)
  const entriesLoading = ref(false)
  const allMachines = ref<VendingMachineBasic[]>([])

  // ── Activity logging (same pattern as useMachineTrays) ───────────────────

  async function logActivity(action: string, entityId: string | null, metadata: Record<string, unknown>) {
    try {
      const { data: { session } } = await supabase.auth.getSession()
      const u = session?.user ?? null
      const fullName = [u?.user_metadata?.first_name, u?.user_metadata?.last_name]
        .filter(Boolean).join(' ').trim()
      const userDisplay = fullName || u?.email || null

      await (supabase as any).from('activity_log').insert({
        company_id: organization.value?.id,
        user_id: u?.id ?? null,
        entity_type: 'cash_book',
        entity_id: entityId,
        action,
        metadata: {
          ...metadata,
          _user_email: u?.email ?? null,
          _user_display: userDisplay,
        },
      })
    } catch (err) {
      console.warn('activity_log insert failed:', err)
    }
  }

  // ── User name resolution ────────────────────────────────────────────────

  async function enrichEntriesWithUsers(rawEntries: CashBookEntry[]): Promise<CashBookEntry[]> {
    const unknownIds = [...new Set(
      rawEntries
        .map(e => e.created_by)
        .filter(id => id && !userCache.has(id))
    )]

    if (unknownIds.length > 0) {
      const { data: users } = await (supabase as any)
        .from('users')
        .select('id, email, first_name, last_name')
        .in('id', unknownIds)

      for (const u of users ?? []) {
        const name = [u.first_name, u.last_name].filter(Boolean).join(' ').trim()
        userCache.set(u.id, name || u.email || u.id.slice(0, 8))
      }
    }

    return rawEntries.map(e => ({
      ...e,
      user_display: userCache.get(e.created_by) || e.created_by?.slice(0, 8) || 'Unbekannt',
    }))
  }

  function getMemberName(userId: string): string {
    return userCache.get(userId) || 'Unbekannt'
  }

  // ── Cash book CRUD ──────────────────────────────────────────────────────

  async function fetchCashBooks() {
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('cash_books')
        .select('*')
        .order('name')

      if (error) throw error
      cashBooks.value = (data ?? []) as CashBook[]

      // If nothing is selected yet, auto-select the first Barkasse so the
      // page loads with content immediately. Users with multiple Barkassen
      // can switch via the dropdown in the header. If a previously selected
      // Barkasse no longer exists, fall back to the first one.
      if (cashBooks.value.length > 0) {
        const stillValid = selectedCashBook.value
          && cashBooks.value.some(cb => cb.id === selectedCashBook.value!.id)
        if (!stillValid) {
          selectedCashBook.value = cashBooks.value[0]!
        }
      } else {
        selectedCashBook.value = null
      }
    } finally {
      loading.value = false
    }
  }

  async function createCashBook(name: string, initialBalance: number, threshold: number = 500, trackPerMachine: boolean = false) {
    const { data: { session } } = await supabase.auth.getSession()
    if (!session?.user) throw new Error('Not authenticated')

    const { data, error } = await (supabase as any)
      .from('cash_books')
      .insert({
        company_id: organization.value?.id,
        name,
        initial_balance: initialBalance,
        bank_deposit_threshold: threshold,
        track_per_machine: trackPerMachine,
        created_by: session.user.id,
      })
      .select()
      .single()

    if (error) throw error

    await logActivity('cash_book_created', data.id, { name, initial_balance: initialBalance, threshold, track_per_machine: trackPerMachine })

    await fetchCashBooks()

    // Auto-select the newly created one
    const created = cashBooks.value.find(cb => cb.id === data.id)
    if (created) selectedCashBook.value = created

    return data as CashBook
  }

  async function deleteCashBook(cashBookId: string) {
    const { data, error } = await (supabase as any)
      .rpc('delete_cash_book', {
        p_cash_book_id: cashBookId,
        p_company_id: organization.value?.id,
      })

    if (error) throw error

    await logActivity('cash_book_deleted', cashBookId, {})

    // Clear selection if deleted
    if (selectedCashBook.value?.id === cashBookId) {
      selectedCashBook.value = null
      entries.value = []
      theoreticalCash.value = null
    }

    await fetchCashBooks()
    return data
  }

  // ── Entries ──────────────────────────────────────────────────────────────

  async function fetchEntries(cashBookId: string, options?: { from?: string; to?: string }) {
    entriesLoading.value = true
    try {
      let query = (supabase as any)
        .from('cash_book_entries')
        .select('*')
        .eq('cash_book_id', cashBookId)
        .order('entry_number', { ascending: false })

      if (options?.from) {
        query = query.gte('created_at', options.from)
      }
      if (options?.to) {
        const nextDay = new Date(options.to)
        nextDay.setDate(nextDay.getDate() + 1)
        query = query.lt('created_at', nextDay.toISOString().split('T')[0])
      }

      const { data, error } = await query

      if (error) throw error
      entries.value = await enrichEntriesWithUsers((data ?? []) as CashBookEntry[])
    } finally {
      entriesLoading.value = false
    }
  }

  async function createEntry(entry: {
    cash_book_id: string
    type: 'withdrawal' | 'correction' | 'payout' | 'expense' | 'change_float' | 'reversal'
    amount: number
    description?: string | null
    machine_id?: string | null
    counted_amount?: number | null
    expected_amount?: number | null
    category?: string | null
    receipt_reference?: string | null
    corrects_entry_id?: string | null
  }) {
    const { data: { session } } = await supabase.auth.getSession()
    if (!session?.user) throw new Error('Not authenticated')

    const { data, error } = await (supabase as any)
      .from('cash_book_entries')
      .insert({
        ...entry,
        company_id: organization.value?.id,
        created_by: session.user.id,
      })
      .select()
      .single()

    if (error) throw error

    await logActivity('cash_book_entry_created', data.id, {
      cash_book_id: entry.cash_book_id,
      type: entry.type,
      amount: entry.amount,
      description: entry.description,
      category: entry.category ?? null,
    })

    // Refresh entries and theoretical cash
    await fetchEntries(entry.cash_book_id)
    await fetchTheoreticalCash(entry.cash_book_id)

    return data as CashBookEntry
  }

  // ── Theoretical cash RPC ────────────────────────────────────────────────

  async function fetchTheoreticalCash(cashBookId: string) {
    const { data, error } = await (supabase as any)
      .rpc('get_theoretical_cash', {
        p_cash_book_id: cashBookId,
        p_company_id: organization.value?.id,
      })

    if (error) throw error
    theoreticalCash.value = data as TheoreticalCash | null
  }

  // ── Wechselgeld-Bestand ──────────────────────────────────────────────────

  /** Wirft nie — ein fehlgeschlagener Wechselgeld-Ladevorgang darf den Rest von
   *  loadCashBookData() (insb. die Hash-Ketten-Prüfung) nicht per Promise.all-
   *  Abbruch mit sich reißen. Stattdessen wird changeFloatUnavailable gesetzt,
   *  damit die UI eine Warnung statt eines stillschweigend leeren Bestands zeigt. */
  async function fetchChangeFloat() {
    const companyId = organization.value?.id
    if (!companyId) {
      // Keine Organisation geladen — kann während des initialen Ladens kurz
      // auftreten. Nicht Mitglied dieser Firma und "kein Wechselgeld
      // vorgestreckt" ([]) müssen unterscheidbar bleiben.
      changeFloat.value = []
      changeFloatUnavailable.value = true
      return
    }

    const { data, error } = await (supabase as any)
      .rpc('get_machine_change_float', {
        p_company_id: companyId,
      })

    // NULL heißt "nicht Mitglied dieser Firma" und ist etwas anderes als
    // [] ("kein Wechselgeld vorgestreckt") — nicht stillschweigend einebnen.
    if (error || data === null) {
      changeFloat.value = []
      changeFloatUnavailable.value = true
      return
    }

    changeFloat.value = data as MachineChangeFloat[]
    changeFloatUnavailable.value = false
  }

  /** Bucht eine Entnahme, optional mit Wechselgeld-Rücklage in die Münztuben.
   *  Beide Zeilen entstehen serverseitig in einer Transaktion. */
  async function recordWithdrawal(payload: {
    cash_book_id: string
    machine_id: string | null
    counted: number
    expected: number
    float_back: number
    description: string
    float_description: string
  }) {
    const { data, error } = await (supabase as any)
      .rpc('record_cash_book_withdrawal', {
        p_cash_book_id: payload.cash_book_id,
        p_machine_id: payload.machine_id,
        p_counted: payload.counted,
        p_expected: payload.expected,
        p_float_back: payload.float_back,
        p_description: payload.description,
        p_float_description: payload.float_description,
      })

    if (error) throw error

    const result = data as { withdrawal_entry_id: string; change_float_entry_id: string | null }

    await logActivity('cash_book_entry_created', result.withdrawal_entry_id, {
      cash_book_id: payload.cash_book_id,
      type: 'withdrawal',
      amount: payload.counted,
      description: payload.description,
      category: null,
    })

    if (result.change_float_entry_id) {
      await logActivity('cash_book_entry_created', result.change_float_entry_id, {
        cash_book_id: payload.cash_book_id,
        type: 'change_float',
        amount: -Math.abs(payload.float_back),
        description: payload.float_description,
        category: null,
      })
    }

    await fetchEntries(payload.cash_book_id)
    await fetchTheoreticalCash(payload.cash_book_id)
    await fetchChangeFloat()

    return result
  }

  /** Storniert einen Eintrag. Hat er eine verkettete Gegenzeile — eine
   *  Wechselgeld-Rücklage zu einer Entnahme —, wird sie in derselben
   *  Transaktion mitstorniert. Ohne das bliebe sie verwaist zurück und der
   *  Automat führte dauerhaft Wechselgeld, das längst zurück ist. */
  async function reverseEntry(entryId: string) {
    const { data, error } = await (supabase as any)
      .rpc('reverse_cash_book_entry', { p_entry_id: entryId })

    if (error) throw error

    const result = data as { reversal_entry_id: string; paired_reversal_entry_id: string | null }

    await logActivity('cash_book_entry_created', result.reversal_entry_id, {
      cash_book_id: selectedCashBook.value?.id,
      type: 'reversal',
      amount: 0,
      description: null,
      category: null,
    })
    if (result.paired_reversal_entry_id) {
      await logActivity('cash_book_entry_created', result.paired_reversal_entry_id, {
        cash_book_id: selectedCashBook.value?.id,
        type: 'reversal',
        amount: 0,
        description: null,
        category: null,
      })
    }

    if (selectedCashBook.value) {
      await fetchEntries(selectedCashBook.value.id)
      await fetchTheoreticalCash(selectedCashBook.value.id)
      await fetchChangeFloat()
    }

    return result
  }

  // ── Machine assignment ──────────────────────────────────────────────────

  async function fetchAllMachines() {
    const { data, error } = await (supabase as any)
      .from('vendingMachine')
      .select('id, name, cash_book_id')
      .order('name')

    if (error) throw error
    allMachines.value = (data ?? []) as VendingMachineBasic[]
  }

  async function assignMachine(machineId: string, cashBookId: string) {
    const { error } = await (supabase as any)
      .from('vendingMachine')
      .update({ cash_book_id: cashBookId })
      .eq('id', machineId)

    if (error) throw error

    // Update local state
    const machine = allMachines.value.find(m => m.id === machineId)
    if (machine) machine.cash_book_id = cashBookId

    await logActivity('machine_assigned_to_cash_book', machineId, {
      cash_book_id: cashBookId,
      machine_name: machine?.name,
    })
  }

  async function unassignMachine(machineId: string) {
    const { error } = await (supabase as any)
      .from('vendingMachine')
      .update({ cash_book_id: null })
      .eq('id', machineId)

    if (error) throw error

    const machine = allMachines.value.find(m => m.id === machineId)
    if (machine) machine.cash_book_id = null

    await logActivity('machine_unassigned_from_cash_book', machineId, {
      machine_name: machine?.name,
    })
  }

  async function updateBarkasseSettings(cashBookId: string, settings: BarkasseSettings) {
    if (settings.bank_deposit_threshold !== undefined && settings.bank_deposit_threshold < 1) {
      throw new Error('Schwellenwert muss mindestens 1 € sein')
    }

    const patch: Record<string, unknown> = {}
    if (settings.bank_deposit_threshold !== undefined) patch.bank_deposit_threshold = settings.bank_deposit_threshold
    if (settings.track_per_machine !== undefined) patch.track_per_machine = settings.track_per_machine

    if (Object.keys(patch).length === 0) return

    const { error } = await (supabase as any)
      .from('cash_books')
      .update(patch)
      .eq('id', cashBookId)

    if (error) throw error

    const cb = cashBooks.value.find(c => c.id === cashBookId)
    if (cb) Object.assign(cb, patch)
    if (selectedCashBook.value?.id === cashBookId) {
      selectedCashBook.value = { ...selectedCashBook.value, ...patch } as CashBook
    }

    await logActivity('cash_book_settings_updated', cashBookId, patch)
  }

  // ── Integrity verification (client-side hash chain) ──────────────────────

  async function verifyIntegrity(entriesToCheck: CashBookEntry[]): Promise<{ verified: number; total: number; valid: boolean }> {
    // Sort ascending by entry_number for chain verification
    const sorted = [...entriesToCheck].sort((a, b) => a.entry_number - b.entry_number)
    let verified = 0
    let prevHash = ''

    for (const entry of sorted) {
      const input = entry.entry_number.toString() + entry.type + entry.amount.toString() + entry.balance_after.toString() + prevHash
      const encoder = new TextEncoder()
      const data = encoder.encode(input)
      const hashBuffer = await crypto.subtle.digest('SHA-256', data)
      const hashArray = Array.from(new Uint8Array(hashBuffer))
      const computedHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('')

      if (computedHash === entry.hash) {
        verified++
      }
      prevHash = entry.hash
    }

    return {
      verified,
      total: sorted.length,
      valid: verified === sorted.length,
    }
  }

  // ── Computed helpers for KPIs ───────────────────────────────────────────

  const currentBalance = computed(() => {
    if (entries.value.length === 0) return 0
    // Entries are sorted DESC by entry_number, first one is latest
    return entries.value[0]!.balance_after
  })

  const totalWithdrawals = computed(() => {
    const withdrawals = entries.value.filter(e => e.type === 'withdrawal' && !e.is_reversed)
    return {
      amount: withdrawals.reduce((sum, e) => sum + Math.abs(e.amount), 0),
      count: withdrawals.length,
    }
  })

  const totalCorrections = computed(() => {
    const corrections = entries.value.filter(e => e.type === 'correction' && !e.is_reversed)
    return {
      amount: corrections.reduce((sum, e) => sum + e.amount, 0),
      count: corrections.length,
    }
  })

  const totalExpenses = computed(() => {
    const expenses = entries.value.filter(e => e.type === 'expense' && !e.is_reversed)
    return {
      amount: expenses.reduce((sum, e) => sum + Math.abs(e.amount), 0),
      count: expenses.length,
    }
  })

  // Most recent non-reversed bank deposit. Invariant: `entries.value` is sorted
  // DESC by `entry_number` (set by fetchEntries' .order('entry_number', desc)),
  // so the first match is the most recent payout.
  const lastBankDeposit = computed<CashBookEntry | null>(() =>
    entries.value.find(e => e.type === 'payout' && !e.is_reversed) ?? null,
  )

  // ── Return ──────────────────────────────────────────────────────────────

  return {
    // State
    cashBooks,
    selectedCashBook,
    entries,
    theoreticalCash,
    changeFloat,
    changeFloatUnavailable,
    loading,
    entriesLoading,
    allMachines,

    // Cash book CRUD
    fetchCashBooks,
    createCashBook,
    deleteCashBook,

    // Entries
    fetchEntries,
    createEntry,
    recordWithdrawal,
    reverseEntry,

    // Theoretical cash
    fetchTheoreticalCash,
    fetchChangeFloat,

    // Machine assignment
    fetchAllMachines,
    assignMachine,
    unassignMachine,

    // Integrity
    verifyIntegrity,

    // User names
    getMemberName,

    // Computed KPIs
    currentBalance,
    totalWithdrawals,
    totalCorrections,
    totalExpenses,
    lastBankDeposit,

    // Settings
    updateBarkasseSettings,
  }
}
