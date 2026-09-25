// Prepaid RFID card accounts — the balances behind the serial card reader on
// the device's pulse input.
//
// The reader publishes a card serial, mqtt-webhook resolves it to an account
// *by name containing that serial*, and hands the balance to the machine as
// MDB credit. So renaming "04A1B2C3" to "Jane Doe (04A1B2C3)" keeps the card
// working; dropping the serial from the name breaks it, which is why the
// editor here warns instead of silently accepting it.

export interface CardAccount {
  id: string
  created_at: string
  updated_at: string
  company_id: string
  name: string
  balance: number
  is_active: boolean
  last_seen_at: string | null
}

export interface CardAccountTransaction {
  id: string
  created_at: string
  account_id: string
  amount: number
  balance_after: number
  type: 'topup' | 'vend' | 'adjustment' | 'refund'
  sale_id: string | null
  embedded_id: string | null
  description: string | null
  created_by: string | null
}

/** Uppercase hex runs of 8+ characters — what an auto-created account is named. */
const SERIAL_RE = /[0-9A-F]{8,}/g

export function extractCardSerials(name: string): string[] {
  return (name.toUpperCase().match(SERIAL_RE) ?? [])
}

/**
 * True when `next` still carries every serial `previous` did. Renaming is the
 * one edit that can quietly orphan a physical card, so the UI checks first.
 */
export function keepsCardSerials(previous: string, next: string): boolean {
  const upper = next.toUpperCase()
  return extractCardSerials(previous).every(s => upper.includes(s))
}

export function useCardAccounts() {
  const supabase = useSupabaseClient()
  const { organization } = useOrganization()

  const accounts = ref<CardAccount[]>([])
  const transactions = ref<CardAccountTransaction[]>([])
  const loading = ref(false)
  const transactionsLoading = ref(false)

  const totalBalance = computed(() =>
    accounts.value.reduce((sum, a) => sum + (a.balance ?? 0), 0),
  )

  async function fetchAccounts() {
    loading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('card_accounts')
        .select('*')
        .order('name')

      if (error) throw error
      accounts.value = (data ?? []) as CardAccount[]
    } finally {
      loading.value = false
    }
  }

  async function fetchTransactions(accountId: string, limit = 50) {
    transactionsLoading.value = true
    try {
      const { data, error } = await (supabase as any)
        .from('card_account_transactions')
        .select('*')
        .eq('account_id', accountId)
        .order('created_at', { ascending: false })
        .limit(limit)

      if (error) throw error
      transactions.value = (data ?? []) as CardAccountTransaction[]
    } finally {
      transactionsLoading.value = false
    }
  }

  async function createAccount(name: string) {
    const { data, error } = await (supabase as any)
      .from('card_accounts')
      .insert({ company_id: organization.value?.id, name: name.trim() })
      .select()
      .single()

    if (error) throw error
    await fetchAccounts()
    return data as CardAccount
  }

  async function updateAccount(id: string, patch: Partial<Pick<CardAccount, 'name' | 'is_active'>>) {
    const payload: Record<string, unknown> = { ...patch, updated_at: new Date().toISOString() }
    if (typeof payload.name === 'string') payload.name = payload.name.trim()

    const { error } = await (supabase as any)
      .from('card_accounts')
      .update(payload)
      .eq('id', id)

    if (error) throw error
    await fetchAccounts()
  }

  async function deleteAccount(id: string) {
    const { error } = await (supabase as any)
      .from('card_accounts')
      .delete()
      .eq('id', id)

    if (error) throw error
    await fetchAccounts()
  }

  /**
   * Signed: positive tops up, negative corrects. Always through the RPC —
   * that is what writes the ledger row alongside the new balance, so the two
   * can never drift apart.
   */
  async function adjustBalance(id: string, amount: number, description?: string) {
    const { data, error } = await (supabase as any).rpc('card_account_topup', {
      p_account_id: id,
      p_amount: amount,
      p_description: description ?? null,
    })

    if (error) throw error
    await fetchAccounts()
    return data as number
  }

  return {
    accounts,
    transactions,
    loading,
    transactionsLoading,
    totalBalance,
    fetchAccounts,
    fetchTransactions,
    createAccount,
    updateAccount,
    deleteAccount,
    adjustBalance,
  }
}
