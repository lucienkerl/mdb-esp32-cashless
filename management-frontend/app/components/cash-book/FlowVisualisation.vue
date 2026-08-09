<script setup lang="ts">
import { IconArrowDown, IconBuildingBank } from '@tabler/icons-vue'
import type { CashBookEntry, TheoreticalCash } from '@/composables/useCashBook'

const props = defineProps<{
  theoreticalCash: TheoreticalCash | null
  currentBalance: number
  lastEntryAt: string | null
  lastBankDeposit: CashBookEntry | null
  bankDepositThreshold: number
}>()

const emit = defineEmits<{
  (e: 'withdraw'): void
  (e: 'deposit'): void
}>()

const { t } = useI18n()

const withdrawalNeeded = computed(() =>
  (props.theoreticalCash?.cash_sales_since ?? 0) > 0,
)

const depositNeeded = computed(() =>
  props.currentBalance >= props.bankDepositThreshold,
)

const ringClass = 'ring-2 ring-amber-400/60 dark:ring-amber-500/60 animate-pulse'
</script>

<template>
  <div class="flex flex-col gap-4">
    <!-- Mobile (stacked vertical with arrows) -->
    <div class="flex flex-col gap-3 sm:hidden">
      <CashBookStationInMachines :theoretical-cash="theoreticalCash" />
      <div class="flex flex-col items-center gap-2">
        <IconArrowDown class="size-5 text-muted-foreground" />
        <button
          class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700"
          :class="[withdrawalNeeded ? ringClass : '']"
          @click="emit('withdraw')"
        >
          <IconArrowDown class="size-4" />
          {{ t('cashBook.recordWithdrawal') }}
        </button>
        <IconArrowDown class="size-5 text-muted-foreground" />
      </div>
      <CashBookStationInBox :current-balance="currentBalance" :last-entry-at="lastEntryAt" />
      <div class="flex flex-col items-center gap-2">
        <IconArrowDown class="size-5 text-muted-foreground" />
        <button
          class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent"
          :class="[depositNeeded ? ringClass : '']"
          @click="emit('deposit')"
        >
          <IconBuildingBank class="size-4" />
          {{ t('cashBook.recordPayout') }}
        </button>
        <IconArrowDown class="size-5 text-muted-foreground" />
      </div>
      <CashBookStationLastBankDeposit :last-bank-deposit="lastBankDeposit" />
    </div>

    <!-- Desktop (3 columns, buttons under arrows 1+2) -->
    <div class="hidden sm:grid sm:grid-cols-3 sm:gap-4">
      <CashBookStationInMachines :theoretical-cash="theoreticalCash" />
      <CashBookStationInBox :current-balance="currentBalance" :last-entry-at="lastEntryAt" />
      <CashBookStationLastBankDeposit :last-bank-deposit="lastBankDeposit" />
    </div>

    <div class="hidden sm:grid sm:grid-cols-3 sm:gap-4">
      <div class="flex justify-center">
        <button
          class="inline-flex h-10 items-center gap-2 rounded-md bg-green-600 px-4 text-sm font-medium text-white hover:bg-green-700"
          :class="[withdrawalNeeded ? ringClass : '']"
          @click="emit('withdraw')"
        >
          <IconArrowDown class="size-4" />
          {{ t('cashBook.recordWithdrawal') }}
        </button>
      </div>
      <div class="flex justify-center">
        <button
          class="inline-flex h-10 items-center gap-2 rounded-md border border-input bg-background px-4 text-sm font-medium hover:bg-accent"
          :class="[depositNeeded ? ringClass : '']"
          @click="emit('deposit')"
        >
          <IconBuildingBank class="size-4" />
          {{ t('cashBook.recordPayout') }}
        </button>
      </div>
      <div></div>
    </div>
  </div>
</template>
