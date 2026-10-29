<script setup lang="ts">
import { IconReceipt2, IconPlus, IconPencil, IconTrash } from '@tabler/icons-vue'

const { t } = useI18n()
const { organization, role } = useOrganization()

// ── Tax Settings (admin only) ───────────────────────────────────────────────
const {
  taxClasses,
  taxRates,
  companyCountry,
  fetchAll: fetchTaxAll,
  createTaxClass,
  updateTaxClass,
  deleteTaxClass,
  createTaxRate,
  deleteTaxRate,
  updateCompanyCountry,
  seedFromSystem,
  getCurrentRate,
  backfillSales,
} = useTaxSettings()
const { COUNTRY_OPTIONS } = await import('~/composables/useTaxSettings')

const taxError = ref('')
const taxSuccess = ref('')
const showTaxClassModal = ref(false)
const editingTaxClass = ref<{ id: string; name: string; description: string | null } | null>(null)
const taxClassForm = ref({ name: '', description: '' })
const taxClassLoading = ref(false)

const showTaxRateModal = ref(false)
const taxRateForm = ref({ taxClassId: '', rate: '', name: '', validFrom: '', validTo: '' })
const taxRateLoading = ref(false)

// Seed + backfill loading
const seedLoading = ref(false)
const backfillLoading = ref(false)
const backfillResult = ref('')

function openAddTaxClass() {
  editingTaxClass.value = null
  taxClassForm.value = { name: '', description: '' }
  showTaxClassModal.value = true
}

function openEditTaxClass(tc: { id: string; name: string; description: string | null }) {
  editingTaxClass.value = tc
  taxClassForm.value = { name: tc.name, description: tc.description ?? '' }
  showTaxClassModal.value = true
}

async function submitTaxClass() {
  if (!taxClassForm.value.name.trim()) return
  taxClassLoading.value = true
  taxError.value = ''
  try {
    if (editingTaxClass.value) {
      await updateTaxClass(editingTaxClass.value.id, taxClassForm.value.name.trim(), taxClassForm.value.description.trim())
    } else {
      await createTaxClass(taxClassForm.value.name.trim(), taxClassForm.value.description.trim())
    }
    showTaxClassModal.value = false
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    taxClassLoading.value = false
  }
}

async function handleDeleteTaxClass(id: string) {
  if (!confirm(t('settings.deleteTaxClassConfirm'))) return
  try {
    await deleteTaxClass(id)
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  }
}

function openAddTaxRate(taxClassId: string) {
  taxRateForm.value = { taxClassId, rate: '', name: '', validFrom: new Date().toISOString().split('T')[0], validTo: '' }
  showTaxRateModal.value = true
}

async function submitTaxRate() {
  if (!taxRateForm.value.rate || !taxRateForm.value.name.trim()) return
  taxRateLoading.value = true
  taxError.value = ''
  try {
    const rateValue = parseFloat(taxRateForm.value.rate) / 100
    await createTaxRate(
      taxRateForm.value.taxClassId,
      companyCountry.value,
      rateValue,
      taxRateForm.value.name.trim(),
      taxRateForm.value.validFrom,
      taxRateForm.value.validTo || undefined,
    )
    showTaxRateModal.value = false
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    taxRateLoading.value = false
  }
}

async function handleDeleteTaxRate(id: string) {
  try {
    await deleteTaxRate(id)
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  }
}

async function handleCountryChange(code: string) {
  try {
    await updateCompanyCountry(code)
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  }
}

async function handleSeedDefaults() {
  seedLoading.value = true
  taxSuccess.value = ''
  taxError.value = ''
  try {
    await seedFromSystem(companyCountry.value)
    taxSuccess.value = t('settings.seedSuccess')
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    seedLoading.value = false
  }
}

async function handleBackfill() {
  backfillLoading.value = true
  backfillResult.value = ''
  taxError.value = ''
  try {
    const count = await backfillSales()
    backfillResult.value = count > 0
      ? t('settings.backfillSuccess', { count })
      : t('settings.backfillNoChanges')
  } catch (err: unknown) {
    taxError.value = err instanceof Error ? err.message : 'Failed'
  } finally {
    backfillLoading.value = false
  }
}

function ratesForClass(classId: string) {
  return taxRates.value.filter(r => r.tax_class_id === classId && r.country_code === companyCountry.value)
}

const countryLabel = computed(() => {
  return COUNTRY_OPTIONS.find(c => c.code === companyCountry.value)?.label ?? companyCountry.value
})

// Own watcher: only load this card's data
watch(() => organization.value?.id, (id) => {
  if (import.meta.client && id && role.value === 'admin') fetchTaxAll(id)
}, { immediate: true })
</script>

<template>
  <!-- Tax Settings (admin only) -->
  <div class="rounded-xl border bg-card p-6 shadow-sm">
    <div class="mb-5 flex items-center gap-2">
      <IconReceipt2 class="size-5 text-primary" />
      <div>
        <h2 class="text-lg font-semibold">{{ t('settings.taxSettings') }}</h2>
        <p class="text-sm text-muted-foreground">{{ t('settings.taxSettingsDescription') }}</p>
      </div>
    </div>

    <!-- Company country -->
    <div class="mb-6 space-y-2">
      <label class="text-sm font-medium">{{ t('settings.companyCountry') }}</label>
      <select
        :value="companyCountry"
        class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        @change="handleCountryChange(($event.target as HTMLSelectElement).value)"
      >
        <option v-for="c in COUNTRY_OPTIONS" :key="c.code" :value="c.code">
          {{ c.code }} — {{ c.label }}
        </option>
      </select>
      <p class="text-xs text-muted-foreground">{{ t('settings.companyCountryHint') }}</p>
    </div>

    <!-- Seed defaults button -->
    <div class="mb-6">
      <button
        :disabled="seedLoading"
        class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
        @click="handleSeedDefaults"
      >
        <span v-if="seedLoading">{{ t('common.loading') }}</span>
        <span v-else>{{ t('settings.seedFromDefaults', { country: countryLabel }) }}</span>
      </button>
      <button
        :disabled="backfillLoading"
        class="inline-flex h-9 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
        @click="handleBackfill"
      >
        <span v-if="backfillLoading">{{ t('common.loading') }}</span>
        <span v-else>{{ t('settings.backfillSales') }}</span>
      </button>
    </div>
    <p class="mb-2 text-xs text-muted-foreground">{{ t('settings.backfillDescription') }}</p>

    <p v-if="taxError" class="mb-4 text-sm text-destructive">{{ taxError }}</p>
    <p v-if="taxSuccess" class="mb-4 text-sm text-green-600">{{ taxSuccess }}</p>
    <p v-if="backfillResult" class="mb-4 text-sm text-green-600">{{ backfillResult }}</p>

    <!-- Tax classes list -->
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h3 class="text-sm font-medium">{{ t('settings.taxClasses') }}</h3>
        <button
          class="inline-flex h-7 items-center gap-1 rounded-md border border-input bg-background px-2 text-xs font-medium shadow-sm transition-colors hover:bg-muted"
          @click="openAddTaxClass"
        >
          <IconPlus class="size-3.5" />
          {{ t('settings.addTaxClass') }}
        </button>
      </div>

      <div v-if="taxClasses.length === 0" class="text-sm text-muted-foreground">
        {{ t('settings.noTaxClasses') }}
      </div>

      <div v-for="tc in taxClasses" :key="tc.id" class="rounded-lg border p-4">
        <div class="flex items-center justify-between mb-3">
          <div>
            <span class="font-medium text-sm">{{ tc.name }}</span>
            <span v-if="getCurrentRate(tc.id) !== null" class="ml-2 text-xs text-muted-foreground">
              ({{ (getCurrentRate(tc.id)! * 100).toFixed(getCurrentRate(tc.id)! * 100 % 1 === 0 ? 0 : 1) }}%)
            </span>
            <p v-if="tc.description" class="text-xs text-muted-foreground mt-0.5">{{ tc.description }}</p>
          </div>
          <div class="flex items-center gap-1">
            <button
              class="inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
              @click="openEditTaxClass(tc)"
            >
              <IconPencil class="size-3.5" />
            </button>
            <button
              class="inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
              @click="handleDeleteTaxClass(tc.id)"
            >
              <IconTrash class="size-3.5" />
            </button>
          </div>
        </div>

        <!-- Rates for this class in current country -->
        <div class="space-y-1">
          <div
            v-for="rate in ratesForClass(tc.id)"
            :key="rate.id"
            class="flex items-center justify-between text-sm rounded-md bg-muted/50 px-3 py-1.5"
          >
            <span>{{ rate.name }} — {{ rate.country_code }}</span>
            <div class="flex items-center gap-2">
              <span class="text-xs text-muted-foreground">
                {{ rate.valid_from }}
                <template v-if="rate.valid_to"> — {{ rate.valid_to }}</template>
              </span>
              <button
                class="text-xs text-destructive hover:underline"
                @click="handleDeleteTaxRate(rate.id)"
              >
                {{ t('common.remove') }}
              </button>
            </div>
          </div>
          <div v-if="ratesForClass(tc.id).length === 0" class="text-xs text-muted-foreground italic px-3 py-1.5">
            {{ t('settings.noTaxRates') }}
          </div>
          <button
            class="mt-1 text-xs text-primary hover:underline"
            @click="openAddTaxRate(tc.id)"
          >
            + {{ t('settings.taxRate') }}
          </button>
        </div>
      </div>
    </div>
  </div>

  <!-- Tax class modal -->
  <AppModal
    v-model:open="showTaxClassModal"
    :title="editingTaxClass ? t('settings.editTaxClass') : t('settings.addTaxClass')"
    size="sm"
  >
    <form class="space-y-4" @submit.prevent="submitTaxClass">
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('settings.className') }}</label>
        <input
          v-model="taxClassForm.name"
          type="text"
          required
          :placeholder="t('settings.className')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('common.description') }}</label>
        <input
          v-model="taxClassForm.description"
          type="text"
          :placeholder="t('common.description')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="showTaxClassModal = false"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="taxClassLoading"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="taxClassLoading">{{ t('common.saving') }}</span>
          <span v-else>{{ t('common.save') }}</span>
        </button>
      </div>
    </form>
  </AppModal>

  <!-- Tax rate modal -->
  <AppModal
    v-model:open="showTaxRateModal"
    :title="t('settings.taxRate')"
    size="sm"
  >
    <form class="space-y-4" @submit.prevent="submitTaxRate">
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('settings.taxRate') }} (%)</label>
        <input
          v-model="taxRateForm.rate"
          type="number"
          step="0.01"
          required
          placeholder="19"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="space-y-1">
        <label class="text-sm font-medium">{{ t('common.name') }}</label>
        <input
          v-model="taxRateForm.name"
          type="text"
          required
          :placeholder="t('settings.taxNamePlaceholder')"
          class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
        />
      </div>
      <div class="grid grid-cols-2 gap-3">
        <div class="space-y-1">
          <label class="text-sm font-medium">{{ t('settings.validFrom') }}</label>
          <input
            v-model="taxRateForm.validFrom"
            type="date"
            required
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
        <div class="space-y-1">
          <label class="text-sm font-medium">{{ t('settings.validTo') }} <span class="text-xs text-muted-foreground">({{ t('common.optional') }})</span></label>
          <input
            v-model="taxRateForm.validTo"
            type="date"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
        </div>
      </div>
      <div class="flex gap-2">
        <button
          type="button"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md border px-4 text-sm font-medium shadow-sm transition-colors hover:bg-muted"
          @click="showTaxRateModal = false"
        >
          {{ t('common.cancel') }}
        </button>
        <button
          type="submit"
          :disabled="taxRateLoading"
          class="inline-flex h-9 flex-1 items-center justify-center rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow transition-colors hover:bg-primary/90 disabled:opacity-50"
        >
          <span v-if="taxRateLoading">{{ t('common.saving') }}</span>
          <span v-else>{{ t('common.save') }}</span>
        </button>
      </div>
    </form>
  </AppModal>
</template>
