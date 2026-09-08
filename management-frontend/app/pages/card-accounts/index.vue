<script setup lang="ts">
definePageMeta({ middleware: 'auth' })

import { formatCurrency, formatDate, timeAgo } from '@/lib/utils'
import { fuzzyFilter } from '@/lib/fuzzySearch'
import { keepsCardSerials, type CardAccount, type CardAccountTransaction } from '@/composables/useCardAccounts'

const { t } = useI18n()
const { role } = useOrganization()
const isAdmin = computed(() => role.value === 'admin')

const {
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
} = useCardAccounts()

const search = ref('')
const { toggleSort, sortIcon, sortKey, sortDir } = useTableSort<'name' | 'balance' | 'lastSeen'>('name', 'asc')

const sortedAccounts = computed(() => {
  const filtered = fuzzyFilter(accounts.value, search.value, [a => a.name])
  const dir = sortDir.value === 'asc' ? 1 : -1
  return [...filtered].sort((a, b) => {
    if (sortKey.value === 'balance') return dir * (a.balance - b.balance)
    if (sortKey.value === 'lastSeen') {
      const aD = a.last_seen_at ?? ''
      const bD = b.last_seen_at ?? ''
      if (!aD && !bD) return 0
      if (!aD) return dir
      if (!bD) return -dir
      return dir * aD.localeCompare(bD)
    }
    return dir * a.name.localeCompare(b.name)
  })
})

onMounted(fetchAccounts)

// ── Create ────────────────────────────────────────────────────────────────
const {
  open: showCreateModal,
  form: createForm,
  loading: createLoading,
  error: createError,
  openModal: openCreateModal,
  closeModal: closeCreateModal,
  submit: submitCreateForm,
} = useModalForm({ name: '' })

async function submitCreate() {
  const name = createForm.value.name.trim()
  if (!name) {
    createError.value = t('common.required', { field: t('common.name') })
    return
  }
  await submitCreateForm(async () => {
    await createAccount(name)
  })
}

// ── Edit (rename / block) ─────────────────────────────────────────────────
const editing = ref<CardAccount | null>(null)
const editName = ref('')
const editActive = ref(true)
const editError = ref('')
const editSaving = ref(false)

// Renaming is the one edit that can orphan a physical card, because the
// reader finds the account by the serial inside the name.
const renameLosesSerial = computed(() =>
  !!editing.value && !keepsCardSerials(editing.value.name, editName.value),
)

function openEdit(account: CardAccount) {
  editing.value = account
  editName.value = account.name
  editActive.value = account.is_active
  editError.value = ''
}

async function saveEdit() {
  if (!editing.value) return
  const name = editName.value.trim()
  if (!name) {
    editError.value = t('common.required', { field: t('common.name') })
    return
  }
  editSaving.value = true
  editError.value = ''
  try {
    await updateAccount(editing.value.id, { name, is_active: editActive.value })
    editing.value = null
  } catch (err: any) {
    editError.value = err?.message ?? String(err)
  } finally {
    editSaving.value = false
  }
}

async function removeAccount(account: CardAccount) {
  if (!confirm(t('cardAccounts.deleteConfirm', { name: account.name }))) return
  await deleteAccount(account.id)
}

// ── Top up / correct ──────────────────────────────────────────────────────
const toppingUp = ref<CardAccount | null>(null)
const topUpAmount = ref<number | null>(null)
const topUpNote = ref('')
const topUpError = ref('')
const topUpSaving = ref(false)

function openTopUp(account: CardAccount) {
  toppingUp.value = account
  topUpAmount.value = null
  topUpNote.value = ''
  topUpError.value = ''
}

async function saveTopUp() {
  if (!toppingUp.value) return
  const amount = Number(topUpAmount.value)
  if (!Number.isFinite(amount) || amount === 0) {
    topUpError.value = t('cardAccounts.amountRequired')
    return
  }
  topUpSaving.value = true
  topUpError.value = ''
  try {
    await adjustBalance(toppingUp.value.id, amount, topUpNote.value.trim() || undefined)
    toppingUp.value = null
  } catch (err: any) {
    topUpError.value = err?.message ?? String(err)
  } finally {
    topUpSaving.value = false
  }
}

// ── History ───────────────────────────────────────────────────────────────
const historyFor = ref<CardAccount | null>(null)

async function openHistory(account: CardAccount) {
  historyFor.value = account
  await fetchTransactions(account.id)
}

function txLabel(type: CardAccountTransaction['type']): string {
  return t(`cardAccounts.tx.${type}`)
}
</script>

<template>
  <div class="flex flex-1 flex-col gap-6 p-4 md:p-6">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold">{{ t('cardAccounts.title') }}</h1>
        <p class="mt-1 text-sm text-muted-foreground">{{ t('cardAccounts.description') }}</p>
      </div>
      <button
        v-if="isAdmin"
        class="shrink-0 inline-flex h-9 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90"
        @click="openCreateModal"
      >
        {{ t('cardAccounts.createAccount') }}
      </button>
    </div>

    <div v-if="loading" class="text-muted-foreground">{{ t('common.loading') }}</div>

    <template v-else>
      <div v-if="accounts.length === 0" class="rounded-xl border bg-card p-6">
        <p class="text-sm text-muted-foreground">{{ t('cardAccounts.empty') }}</p>
      </div>

      <div v-else class="flex flex-col gap-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <SearchInput v-model="search" :placeholder="t('common.search') + '...'" class="max-w-xs" />
          <p class="text-sm text-muted-foreground">
            {{ t('cardAccounts.totalBalance') }}:
            <span class="font-medium text-foreground">{{ formatCurrency(totalBalance) }}</span>
          </p>
        </div>

        <div v-if="sortedAccounts.length === 0" class="text-sm text-muted-foreground">{{ t('common.noResults') }}</div>
        <div v-else class="overflow-x-auto rounded-md border">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b bg-muted/50 text-left">
                <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleSort('name')">
                  <SortHeader :icon="sortIcon('name')">{{ t('common.name') }}</SortHeader>
                </th>
                <th class="px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleSort('balance')">
                  <SortHeader :icon="sortIcon('balance')">{{ t('cardAccounts.balance') }}</SortHeader>
                </th>
                <th class="hidden sm:table-cell px-4 py-3 font-medium cursor-pointer select-none hover:text-foreground" @click="toggleSort('lastSeen')">
                  <SortHeader :icon="sortIcon('lastSeen')">{{ t('cardAccounts.lastSeen') }}</SortHeader>
                </th>
                <th class="px-4 py-3 font-medium">{{ t('common.status') }}</th>
                <th class="px-4 py-3 font-medium">{{ t('common.actions') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr
                v-for="account in sortedAccounts"
                :key="account.id"
                class="border-b last:border-0 transition-colors hover:bg-muted/30"
                :class="account.is_active ? '' : 'opacity-50'"
              >
                <td class="px-4 py-3 font-medium">{{ account.name }}</td>
                <td class="px-4 py-3" :class="account.balance < 0 ? 'text-destructive font-medium' : ''">
                  {{ formatCurrency(account.balance) }}
                </td>
                <td class="hidden sm:table-cell px-4 py-3 text-muted-foreground">
                  {{ account.last_seen_at ? timeAgo(account.last_seen_at, t) : '—' }}
                </td>
                <td class="px-4 py-3">
                  <span
                    class="rounded-full px-2 py-0.5 text-xs font-medium"
                    :class="account.is_active
                      ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400'
                      : 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400'"
                  >
                    {{ account.is_active ? t('cardAccounts.active') : t('cardAccounts.blocked') }}
                  </span>
                </td>
                <td class="px-4 py-3">
                  <div class="flex flex-wrap items-center gap-3">
                    <button class="text-xs text-primary hover:underline" @click="openHistory(account)">
                      {{ t('cardAccounts.history') }}
                    </button>
                    <template v-if="isAdmin">
                      <button class="text-xs text-primary hover:underline" @click="openTopUp(account)">
                        {{ t('cardAccounts.topUp') }}
                      </button>
                      <button class="text-xs text-primary hover:underline" @click="openEdit(account)">
                        {{ t('common.edit') }}
                      </button>
                      <button class="text-xs text-destructive hover:underline" @click="removeAccount(account)">
                        {{ t('common.delete') }}
                      </button>
                    </template>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="rounded-xl border bg-card p-6">
        <h2 class="mb-2 text-base font-medium">{{ t('cardAccounts.howItWorks') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('cardAccounts.howItWorksBody') }}</p>
      </div>
    </template>
  </div>

  <!-- Create -->
  <AppModal :open="showCreateModal" :title="t('cardAccounts.createAccount')" @update:open="(v) => { if (!v) closeCreateModal() }">
    <form class="space-y-4" @submit.prevent="submitCreate">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="card-account-name">{{ t('common.name') }}</label>
        <input
          id="card-account-name"
          v-model="createForm.name"
          type="text"
          required
          :placeholder="t('cardAccounts.namePlaceholder')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="text-xs text-muted-foreground">{{ t('cardAccounts.nameHint') }}</p>
      </div>
      <FormError :message="createError" />
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="closeCreateModal"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="createLoading"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="createLoading">{{ t('common.creating') }}</span>
          <span v-else>{{ t('common.create') }}</span>
        </button>
      </div>
    </form>
  </AppModal>

  <!-- Edit -->
  <AppModal :open="!!editing" :title="t('cardAccounts.editAccount')" @update:open="(v) => { if (!v) editing = null }">
    <form class="space-y-4" @submit.prevent="saveEdit">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="card-account-edit-name">{{ t('common.name') }}</label>
        <input
          id="card-account-edit-name"
          v-model="editName"
          type="text"
          required
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p v-if="renameLosesSerial" class="text-xs text-destructive">{{ t('cardAccounts.renameWarning') }}</p>
        <p v-else class="text-xs text-muted-foreground">{{ t('cardAccounts.nameHint') }}</p>
      </div>
      <label class="flex items-center gap-2 text-sm">
        <input v-model="editActive" type="checkbox" class="h-4 w-4 rounded border-input" />
        {{ t('cardAccounts.activeLabel') }}
      </label>
      <FormError :message="editError" />
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="editing = null"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="editSaving"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="editSaving">{{ t('common.saving') }}</span>
          <span v-else>{{ t('common.save') }}</span>
        </button>
      </div>
    </form>
  </AppModal>

  <!-- Top up -->
  <AppModal :open="!!toppingUp" :title="t('cardAccounts.topUpTitle', { name: toppingUp?.name ?? '' })" @update:open="(v) => { if (!v) toppingUp = null }">
    <form class="space-y-4" @submit.prevent="saveTopUp">
      <div class="space-y-1">
        <label class="text-sm font-medium" for="card-account-amount">{{ t('cardAccounts.amount') }}</label>
        <input
          id="card-account-amount"
          v-model.number="topUpAmount"
          type="number"
          step="0.01"
          required
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
        <p class="text-xs text-muted-foreground">{{ t('cardAccounts.amountHint') }}</p>
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium" for="card-account-note">{{ t('common.notes') }}</label>
        <input
          id="card-account-note"
          v-model="topUpNote"
          type="text"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <FormError :message="topUpError" />
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="toppingUp = null"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="topUpSaving"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="topUpSaving">{{ t('common.saving') }}</span>
          <span v-else>{{ t('common.save') }}</span>
        </button>
      </div>
    </form>
  </AppModal>

  <!-- History -->
  <AppModal :open="!!historyFor" :title="t('cardAccounts.historyTitle', { name: historyFor?.name ?? '' })" @update:open="(v) => { if (!v) historyFor = null }">
    <div v-if="transactionsLoading" class="text-sm text-muted-foreground">{{ t('common.loading') }}</div>
    <div v-else-if="transactions.length === 0" class="text-sm text-muted-foreground">{{ t('common.noData') }}</div>
    <div v-else class="max-h-96 overflow-y-auto">
      <table class="w-full text-sm">
        <tbody>
          <tr v-for="tx in transactions" :key="tx.id" class="border-b last:border-0">
            <td class="py-2 pr-3">
              <p class="font-medium">{{ txLabel(tx.type) }}</p>
              <p class="text-xs text-muted-foreground">{{ formatDate(tx.created_at) }}<span v-if="tx.description"> · {{ tx.description }}</span></p>
            </td>
            <td class="py-2 text-right whitespace-nowrap" :class="tx.amount < 0 ? 'text-destructive' : 'text-green-600 dark:text-green-400'">
              {{ tx.amount > 0 ? '+' : '' }}{{ formatCurrency(tx.amount) }}
            </td>
            <td class="py-2 pl-3 text-right whitespace-nowrap text-muted-foreground">{{ formatCurrency(tx.balance_after) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </AppModal>
</template>
