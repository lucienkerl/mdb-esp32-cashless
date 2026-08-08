<script setup lang="ts">
definePageMeta({ middleware: 'auth', ssr: false })

import { IconCash, IconPlus } from '@tabler/icons-vue'
import { formatCurrency, formatDateTime } from '@/lib/utils'
import type { CashBookEntry } from '@/composables/useCashBook'

const { t } = useI18n()
const { organization } = useOrganization()

const errorMessage = ref<string | null>(null)

const {
  cashBooks,
  selectedCashBook,
  entries,
  theoreticalCash,
  changeFloat,
  changeFloatUnavailable,
  loading,
  entriesLoading,
  allMachines,
  fetchCashBooks,
  createCashBook,
  deleteCashBook,
  fetchEntries,
  createEntry,
  recordWithdrawal,
  reverseEntry,
  fetchTheoreticalCash,
  fetchChangeFloat,
  fetchAllMachines,
  assignMachine,
  unassignMachine,
  verifyIntegrity,
  getMemberName,
  currentBalance,
  totalWithdrawals,
  totalCorrections,
  totalExpenses,
  lastBankDeposit,
  updateBarkasseSettings,
} = useCashBook()

// ── State ────────────────────────────────────────────────────────────────────

const dateFilter = ref<'30' | '90' | 'year' | 'all'>('30')
const integrityResult = ref<{ verified: number; total: number; valid: boolean } | null>(null)

// Modal visibility
const showCreateModal = ref(false)
const showExpenseModal = ref(false)
const showWithdrawalModal = ref(false)
const showPayoutModal = ref(false)
const showCorrectionModal = ref(false)
const showChangeFloatModal = ref(false)
const showAssignModal = ref(false)
const showSettingsModal = ref(false)
const showDeleteModal = ref(false)
const showReversalConfirm = ref(false)

// Async loading flags
const assignLoading = ref(false)
const deleting = ref(false)
const reversalLoading = ref(false)
const withdrawalSubmitting = ref(false)
const changeFloatSubmitting = ref(false)
const bankDepositSubmitting = ref(false)
const correctionSubmitting = ref(false)
const expenseSubmitting = ref(false)

const reversalTarget = ref<CashBookEntry | null>(null)

// ── Date filter computation ──────────────────────────────────────────────────

const dateRange = computed(() => {
  const now = new Date()
  switch (dateFilter.value) {
    case '30': {
      const from = new Date(now)
      from.setDate(from.getDate() - 30)
      return { from: from.toISOString().split('T')[0] }
    }
    case '90': {
      const from = new Date(now)
      from.setDate(from.getDate() - 90)
      return { from: from.toISOString().split('T')[0] }
    }
    case 'year': {
      return { from: `${now.getFullYear()}-01-01` }
    }
    case 'all':
    default:
      return {}
  }
})

// ── Load data ────────────────────────────────────────────────────────────────

async function loadCashBookData() {
  if (!selectedCashBook.value) return
  const id = selectedCashBook.value.id

  await Promise.all([
    fetchEntries(id, dateRange.value),
    fetchTheoreticalCash(id),
    fetchChangeFloat(),
  ])

  const { data: allEntries } = await (useSupabaseClient() as any)
    .from('cash_book_entries')
    .select('*')
    .eq('cash_book_id', id)
    .order('entry_number', { ascending: true })

  if (allEntries) {
    integrityResult.value = await verifyIntegrity(allEntries as CashBookEntry[])
  }
}

onMounted(async () => {
  if (!import.meta.server && organization.value?.id) {
    await fetchCashBooks()
    if (selectedCashBook.value) {
      await loadCashBookData()
    }
  }
})

watch([() => selectedCashBook.value?.id, dateFilter], async () => {
  if (selectedCashBook.value) {
    await loadCashBookData()
  }
})

usePullToRefresh(async () => {
  await fetchCashBooks()
  if (selectedCashBook.value) await loadCashBookData()
})

// ── Cash book selection ──────────────────────────────────────────────────────

function selectCashBook(id: string) {
  selectedCashBook.value = cashBooks.value.find(cb => cb.id === id) ?? null
}

// ── Assigned machines (for withdrawal modal) ────────────────────────────────

const assignedMachines = computed(() =>
  allMachines.value.filter(m => m.cash_book_id === selectedCashBook.value?.id),
)

// ── Action handlers ──────────────────────────────────────────────────────────

async function openWithdrawal() {
  errorMessage.value = null
  if (selectedCashBook.value) {
    await Promise.all([
      fetchTheoreticalCash(selectedCashBook.value.id),
      // Needed when track_per_machine is on, so the modal's machine
      // dropdown has data without first opening "Automaten zuweisen".
      allMachines.value.length === 0 ? fetchAllMachines() : Promise.resolve(),
    ])
  }
  showWithdrawalModal.value = true
}

async function onWithdrawalSubmit(payload: {
  counted: number
  expected: number
  machineId: string | null
  floatBack: number
  floats: { machineId: string; amount: number }[]
  description: string
}) {
  if (!selectedCashBook.value) return
  withdrawalSubmitting.value = true
  try {
    await recordWithdrawal({
      cash_book_id: selectedCashBook.value.id,
      machine_id: payload.machineId,
      counted: payload.counted,
      expected: payload.expected,
      float_back: payload.floatBack,
      floats: payload.floats.map(f => ({ machine_id: f.machineId, amount: f.amount })),
      description: payload.description,
      float_description: t('cashBook.changeFloatIn'),
    })
    // Der Schreibvorgang ist bereits committet, sobald recordWithdrawal
    // zurückkehrt — ein Refetch-Fehler danach wird intern abgefangen und
    // darf den Dialog nicht offen halten (sonst bucht ein Retry doppelt).
    showWithdrawalModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    withdrawalSubmitting.value = false
  }
}

async function onBankDepositSubmit(payload: { amount: number; description: string }) {
  if (!selectedCashBook.value) return
  bankDepositSubmitting.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'payout',
      amount: -Math.abs(payload.amount),
      description: payload.description,
    })
    showPayoutModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    bankDepositSubmitting.value = false
  }
}

async function onCorrectionSubmit(payload: { amount: number; description: string }) {
  if (!selectedCashBook.value) return
  correctionSubmitting.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'correction',
      amount: payload.amount,
      description: payload.description,
    })
    showCorrectionModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    correctionSubmitting.value = false
  }
}

async function onExpenseSubmit(payload: { amount: number; category: string; receiptReference: string; description: string }) {
  if (!selectedCashBook.value) return
  expenseSubmitting.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'expense',
      amount: -Math.abs(payload.amount),
      description: payload.description || null,
      category: payload.category,
      receipt_reference: payload.receiptReference,
    })
    showExpenseModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    expenseSubmitting.value = false
  }
}

function openBankDeposit() {
  errorMessage.value = null
  showPayoutModal.value = true
}

function openCorrection() {
  errorMessage.value = null
  showCorrectionModal.value = true
}

function openExpense() {
  errorMessage.value = null
  showExpenseModal.value = true
}

async function openChangeFloat() {
  errorMessage.value = null
  if (allMachines.value.length === 0) await fetchAllMachines()
  showChangeFloatModal.value = true
}

async function onChangeFloatSubmit(payload: { amount: number; machineId: string; description: string }) {
  if (!selectedCashBook.value) return
  changeFloatSubmitting.value = true
  try {
    await createEntry({
      cash_book_id: selectedCashBook.value.id,
      type: 'change_float',
      amount: payload.amount,
      description: payload.description || null,
      machine_id: payload.machineId,
    })
    await fetchChangeFloat()
    showChangeFloatModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    changeFloatSubmitting.value = false
  }
}

function openReversalConfirm(entry: CashBookEntry) {
  errorMessage.value = null
  reversalTarget.value = entry
  showReversalConfirm.value = true
}

async function submitReversal() {
  if (!selectedCashBook.value || !reversalTarget.value) return
  reversalLoading.value = true
  try {
    await reverseEntry(reversalTarget.value.id)
    showReversalConfirm.value = false
    reversalTarget.value = null
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    reversalLoading.value = false
  }
}

async function openAssignModal() {
  assignLoading.value = true
  showAssignModal.value = true
  await fetchAllMachines()
  assignLoading.value = false
}

async function onMachineToggle(payload: { machineId: string; currentCashBookId: string | null }) {
  if (!selectedCashBook.value) return
  try {
    if (payload.currentCashBookId === selectedCashBook.value.id) {
      await unassignMachine(payload.machineId)
    } else {
      await assignMachine(payload.machineId, selectedCashBook.value.id)
    }
    await fetchTheoreticalCash(selectedCashBook.value.id)
  } catch (err: any) {
    errorMessage.value = err.message
  }
}

async function onCreateBarkasse(payload: { name: string; initialBalance: number; threshold: number; trackPerMachine: boolean }) {
  try {
    await createCashBook(payload.name, payload.initialBalance, payload.threshold, payload.trackPerMachine)
    showCreateModal.value = false
    if (selectedCashBook.value) await loadCashBookData()
  } catch (err: any) {
    errorMessage.value = err.message
  }
}

async function onSettingsSubmit(payload: { threshold: number; trackPerMachine: boolean }) {
  if (!selectedCashBook.value) return
  try {
    await updateBarkasseSettings(selectedCashBook.value.id, {
      bank_deposit_threshold: payload.threshold,
      track_per_machine: payload.trackPerMachine,
    })
    showSettingsModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  }
}

async function confirmDelete() {
  if (!selectedCashBook.value) return
  deleting.value = true
  try {
    await deleteCashBook(selectedCashBook.value.id)
    showDeleteModal.value = false
  } catch (err: any) {
    errorMessage.value = err.message
  } finally {
    deleting.value = false
  }
}

// ── Type label helper used by PDF export ────────────────────────────────────

function typeLabel(type: string, amount?: number): string {
  if (type === 'change_float' && amount !== undefined) {
    return amount < 0 ? t('cashBook.changeFloatIn') : t('cashBook.changeFloatOut')
  }
  const map: Record<string, string> = {
    initial: t('cashBook.typeInitial'),
    withdrawal: t('cashBook.typeWithdrawal'),
    correction: t('cashBook.typeCorrection'),
    payout: t('cashBook.typePayout'),
    expense: t('cashBook.typeExpense'),
    change_float: t('cashBook.typeChangeFloat'),
    reversal: t('cashBook.typeReversal'),
  }
  return map[type] ?? type
}

function formatAmount(amount: number): string {
  const prefix = amount >= 0 ? '+' : ''
  return `${prefix}${formatCurrency(amount)}`
}

// ── PDF Export ───────────────────────────────────────────────────────────────

async function exportPdf() {
  if (!selectedCashBook.value) return

  const { data: allEntries } = await (useSupabaseClient() as any)
    .from('cash_book_entries')
    .select('*')
    .eq('cash_book_id', selectedCashBook.value.id)
    .order('entry_number', { ascending: true })

  if (!allEntries || allEntries.length === 0) return

  const { jsPDF } = await import('jspdf')
  const autoTable = (await import('jspdf-autotable')).default
  const doc = new jsPDF()
  const cb = selectedCashBook.value
  const orgName = organization.value?.name || ''

  doc.setFontSize(18)
  doc.text(t('cashBook.title'), 14, 20)
  doc.setFontSize(12)
  doc.text(cb.name, 14, 28)
  if (orgName) doc.text(orgName, 14, 34)

  const lastEntry = allEntries[allEntries.length - 1]
  const withdrawals = allEntries.filter((e: any) => e.type === 'withdrawal' && !e.is_reversed)
  const corrections = allEntries.filter((e: any) => e.type === 'correction' && !e.is_reversed)
  const totalW = withdrawals.reduce((s: number, e: any) => s + Math.abs(e.amount), 0)
  const changeFloats = allEntries.filter((e: any) => e.type === 'change_float' && !e.is_reversed)
  const totalCF = -changeFloats.reduce((s: number, e: any) => s + e.amount, 0)
  const totalC = corrections.reduce((s: number, e: any) => s + e.amount, 0)

  doc.setFontSize(10)
  let y = orgName ? 44 : 38
  doc.text(`${t('cashBook.currentBalance')}: ${formatCurrency(lastEntry.balance_after)}`, 14, y)
  doc.text(`${t('cashBook.totalWithdrawals')}: ${formatCurrency(totalW)} (${withdrawals.length})`, 14, y + 5)
  doc.text(`${t('cashBook.totalChangeFloat')}: ${formatCurrency(totalCF)} (${changeFloats.length})`, 14, y + 10)
  doc.text(`${t('cashBook.totalCorrections')}: ${formatCurrency(totalC)} (${corrections.length})`, 14, y + 15)
  y += 23

  autoTable(doc, {
    startY: y,
    head: [[
      'Nr',
      t('cashBook.date'),
      t('cashBook.type'),
      t('cashBook.amount'),
      t('cashBook.balanceAfter'),
      t('cashBook.description'),
    ]],
    body: allEntries.map((e: any) => [
      e.entry_number,
      formatDateTime(e.created_at),
      typeLabel(e.type, e.amount) + (e.is_reversed ? ` (${t('cashBook.reversed')})` : ''),
      formatAmount(e.amount),
      formatCurrency(e.balance_after),
      e.type === 'expense'
        ? [t(`cashBook.category_${e.category}`), e.receipt_reference, e.description].filter(Boolean).join(' · ')
        : (e.description || '—'),
    ]),
    styles: { fontSize: 8 },
    headStyles: { fillColor: [41, 128, 185] },
  })

  const finalY = (doc as any).lastAutoTable?.finalY ?? y + 20
  doc.setFontSize(9)
  doc.setTextColor(100)
  doc.text(t('cashBook.gobdCompliance'), 14, finalY + 10)
  doc.text(t('cashBook.gobdDescription'), 14, finalY + 15)
  doc.text(t('cashBook.activatedAt', { date: formatDateTime(cb.activated_at) }), 14, finalY + 20)
  doc.text(t('cashBook.totalEntries', { count: allEntries.length }), 14, finalY + 25)
  doc.text(`Hash: ${lastEntry.hash.slice(0, 32)}...`, 14, finalY + 30)

  const dateStr = new Date().toISOString().split('T')[0]
  doc.save(`Kassenbuch_${cb.name}_${dateStr}.pdf`)
}
</script>

<template>
  <div class="flex flex-col gap-6 px-4 py-6 lg:px-6">
    <!-- Header -->
    <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
      <div>
        <h1 class="text-2xl font-bold">{{ t('cashBook.title') }}</h1>
      </div>

      <div class="flex items-center gap-3">
        <select
          v-if="cashBooks.length > 0"
          :value="selectedCashBook?.id ?? ''"
          class="h-9 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring sm:w-64"
          @change="selectCashBook(($event.target as HTMLSelectElement).value)"
        >
          <option value="" disabled>{{ t('cashBook.selectCashBook') }}</option>
          <option v-for="cb in cashBooks" :key="cb.id" :value="cb.id">
            {{ cb.name }}
          </option>
        </select>

        <button
          class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-3 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          @click="showCreateModal = true"
        >
          <IconPlus class="size-4" />
          <span class="hidden sm:inline">{{ t('cashBook.newCashBook') }}</span>
        </button>
      </div>
    </div>

    <!-- Empty state -->
    <div
      v-if="cashBooks.length === 0 && !loading"
      class="flex flex-col items-center justify-center gap-4 rounded-xl border bg-card p-12 text-center"
    >
      <IconCash class="size-12 text-muted-foreground" />
      <div>
        <h3 class="text-lg font-semibold">{{ t('cashBook.emptyState') }}</h3>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('cashBook.emptyStateDescription') }}</p>
      </div>
      <button
        class="inline-flex h-9 items-center gap-2 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground hover:bg-primary/90"
        @click="showCreateModal = true"
      >
        <IconPlus class="size-4" />
        {{ t('cashBook.createCashBook') }}
      </button>
    </div>

    <!-- Main content -->
    <template v-if="selectedCashBook">
      <!-- Flow visualisation -->
      <CashBookFlowVisualisation
        :theoretical-cash="theoreticalCash"
        :current-balance="currentBalance"
        :last-entry-at="theoreticalCash?.last_entry_at ?? null"
        :last-bank-deposit="lastBankDeposit"
        :bank-deposit-threshold="selectedCashBook.bank_deposit_threshold ?? 500"
        :change-float="changeFloat"
        :cash-book-id="selectedCashBook.id"
        :change-float-unavailable="changeFloatUnavailable"
        @withdraw="openWithdrawal"
        @deposit="openBankDeposit"
      />

      <!-- Error message -->
      <div
        v-if="errorMessage"
        class="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-400"
      >
        {{ errorMessage }}
        <button class="ml-2 underline" @click="errorMessage = null">x</button>
      </div>

      <!-- Secondary toolbar -->
      <CashBookSecondaryToolbar
        @expense="openExpense"
        @correction="openCorrection"
        @change-float="openChangeFloat"
        @manage-machines="openAssignModal"
        @export-pdf="exportPdf"
        @open-settings="showSettingsModal = true"
        @delete="showDeleteModal = true"
      />

      <!-- Entries table -->
      <CashBookEntriesTable
        :entries="entries"
        :loading="entriesLoading"
        :date-filter="dateFilter"
        :integrity-result="integrityResult"
        :total-withdrawals="totalWithdrawals"
        :total-corrections="totalCorrections"
        :total-expenses="totalExpenses"
        :get-member-name="getMemberName"
        @update:date-filter="dateFilter = $event"
        @reverse="openReversalConfirm"
      />

      <!-- GoBD compliance footer -->
      <div class="rounded-xl border bg-card p-4">
        <div class="flex items-start gap-3">
          <div>
            <h3 class="font-semibold">{{ t('cashBook.gobdCompliance') }}</h3>
            <p class="mt-1 text-sm text-muted-foreground">
              {{ t('cashBook.gobdDescription') }}
            </p>
            <div class="mt-2 space-y-0.5 text-sm text-muted-foreground">
              <div>{{ t('cashBook.activatedAt', { date: formatDateTime(selectedCashBook.activated_at) }) }}</div>
              <div>{{ t('cashBook.totalEntries', { count: integrityResult?.total ?? entries.length }) }}</div>
            </div>
          </div>
        </div>
      </div>
    </template>

    <!-- Loading state -->
    <div v-if="loading" class="flex items-center justify-center py-12">
      <span class="text-muted-foreground">{{ t('common.loading') }}</span>
    </div>

    <!-- Modals -->
    <CashBookCreateBarkasseModal
      v-model:open="showCreateModal"
      @submit="onCreateBarkasse"
    />
    <CashBookWithdrawalModal
      v-model:open="showWithdrawalModal"
      :theoretical-cash="theoreticalCash"
      :assigned-machines="assignedMachines"
      :track-per-machine="selectedCashBook?.track_per_machine ?? false"
      :submitting="withdrawalSubmitting"
      :error="errorMessage"
      @submit="onWithdrawalSubmit"
    />
    <CashBookBankDepositModal
      v-model:open="showPayoutModal"
      :current-balance="currentBalance"
      :submitting="bankDepositSubmitting"
      :error="errorMessage"
      @submit="onBankDepositSubmit"
    />
    <CashBookCorrectionModal
      v-model:open="showCorrectionModal"
      :submitting="correctionSubmitting"
      :error="errorMessage"
      @submit="onCorrectionSubmit"
    />
    <CashBookExpenseModal
      v-model:open="showExpenseModal"
      :submitting="expenseSubmitting"
      :error="errorMessage"
      @submit="onExpenseSubmit"
    />
    <CashBookChangeFloatModal
      v-model:open="showChangeFloatModal"
      :assigned-machines="assignedMachines"
      :change-float="changeFloat"
      :change-float-unavailable="changeFloatUnavailable"
      :submitting="changeFloatSubmitting"
      :error="errorMessage"
      @submit="onChangeFloatSubmit"
    />
    <CashBookReversalModal
      v-model:open="showReversalConfirm"
      :entry="reversalTarget"
      :entries="entries"
      :loading="reversalLoading"
      :error="errorMessage"
      @confirm="submitReversal"
    />
    <CashBookAssignMachinesModal
      v-model:open="showAssignModal"
      :loading="assignLoading"
      :all-machines="allMachines"
      :selected-cash-book-id="selectedCashBook?.id ?? ''"
      :cash-books="cashBooks"
      @toggle="onMachineToggle"
    />
    <CashBookBarkasseSettingsModal
      v-model:open="showSettingsModal"
      :initial-threshold="selectedCashBook?.bank_deposit_threshold ?? 500"
      :initial-track-per-machine="selectedCashBook?.track_per_machine ?? false"
      @submit="onSettingsSubmit"
    />
    <CashBookDeleteBarkasseModal
      v-model:open="showDeleteModal"
      :cash-book-name="selectedCashBook?.name ?? ''"
      :entry-count="integrityResult?.total ?? entries.length"
      :loading="deleting"
      @confirm="confirmDelete"
    />
  </div>
</template>
