<script setup lang="ts">
import { ref, computed, watch, onMounted } from 'vue'
import { useI18n, useSupabaseClient } from '#imports'
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from '~/components/ui/dialog'
import { IconTrash } from '@tabler/icons-vue'
import QRCode from 'qrcode'
import LocationPicker, { type LocationModel } from '~/components/LocationPicker.vue'
import { useMachines, type MachineSettingsPatch } from '~/composables/useMachines'
import { useOrganization } from '~/composables/useOrganization'
import { COUNTRY_OPTIONS } from '~/composables/useTaxSettings'
import TemperatureSensorsSettings from '~/components/machine/TemperatureSensorsSettings.vue'
import {
  cleanTempSettings,
  parseTempSettings,
  type TempReading,
  type TempSensorSetting,
} from '~/lib/temperatureSensors'

const props = defineProps<{
  open: boolean
  machineId: string
  /** temp_sensors is the raw `vendingMachine.temp_sensors` column. */
  initial: Partial<LocationModel & { nayax_machine_id: string | null; item_number_offset: number; linked_selections: boolean; temp_sensors: unknown }>
  publicListing: boolean
  /** Latest readings of the board's temperature sensors, to name and pick them. */
  tempReadings?: TempReading[]
}>()

const emit = defineEmits<{
  (e: 'update:open', value: boolean): void
  (e: 'saved'): void
}>()

const { t } = useI18n()
const supabase = useSupabaseClient()
const { updateMachineSettings } = useMachines()

type MachineSettingsForm = LocationModel & { nayax_machine_id: string | null; item_number_offset: number; linked_selections: boolean; temp_sensors: TempSensorSetting[] }

const form = ref<MachineSettingsForm>(cloneInitial())
const saving = ref(false)
const errorMsg = ref<string | null>(null)

// ── Public visibility state ─────────────────────────────────────────────────
const publicListingValue = ref<boolean>(props.publicListing)
const publicListingLoading = ref(false)
const publicListingError = ref('')
const publicUrlCopied = ref(false)
const publicQrDataUrl = ref<string>('')
const publicPageOrigin = ref<string>('')

const publicUrl = computed(() => {
  if (!props.machineId || !publicPageOrigin.value) return ''
  return `${publicPageOrigin.value}/m/${props.machineId}`
})

// ── Per-machine contact overrides (printed posters) ─────────────────────────
// Empty means "inherit from the company", which is why the company value is
// shown as the placeholder: the operator sees what will actually be printed
// without having to open the settings page.
interface ContactOverrides {
  contact_phone: string
  whatsapp_phone: string
  support_hours: string
  contact_email: string
}

const EMPTY_CONTACT: ContactOverrides = {
  contact_phone: '',
  whatsapp_phone: '',
  support_hours: '',
  contact_email: '',
}

const contact = ref<ContactOverrides>({ ...EMPTY_CONTACT })
const companyContact = ref<ContactOverrides>({ ...EMPTY_CONTACT })
const contactOpen = ref(false)

const CONTACT_KEYS = Object.keys(EMPTY_CONTACT) as (keyof ContactOverrides)[]

const hasContactOverride = computed(() =>
  CONTACT_KEYS.some(k => contact.value[k].trim().length > 0),
)

async function loadContact() {
  if (!props.machineId) return
  const { organization } = useOrganization()
  const companyId = organization.value?.id
  const [machineRes, companyRes] = await Promise.all([
    supabase
      .from('vendingMachine')
      .select('contact_phone, whatsapp_phone, support_hours, contact_email')
      .eq('id', props.machineId)
      .single(),
    companyId
      ? supabase
          .from('companies')
          .select('contact_phone, whatsapp_phone, support_hours, contact_email')
          .eq('id', companyId)
          .single()
      : Promise.resolve({ data: null }),
  ])
  const m = machineRes.data as Partial<ContactOverrides> | null
  const c = companyRes.data as Partial<ContactOverrides> | null
  contact.value = {
    contact_phone: m?.contact_phone ?? '',
    whatsapp_phone: m?.whatsapp_phone ?? '',
    support_hours: m?.support_hours ?? '',
    contact_email: m?.contact_email ?? '',
  }
  companyContact.value = {
    contact_phone: c?.contact_phone ?? '',
    whatsapp_phone: c?.whatsapp_phone ?? '',
    support_hours: c?.support_hours ?? '',
    contact_email: c?.contact_email ?? '',
  }
  contactOpen.value = hasContactOverride.value
}

async function saveContact() {
  const norm = (v: string) => {
    const trimmed = v.trim()
    return trimmed.length > 0 ? trimmed : null
  }
  const { error } = await supabase
    .from('vendingMachine')
    .update({
      contact_phone: norm(contact.value.contact_phone),
      whatsapp_phone: norm(contact.value.whatsapp_phone),
      support_hours: norm(contact.value.support_hours),
      contact_email: norm(contact.value.contact_email),
    } as never)
    .eq('id', props.machineId)
  if (error) throw error
}

function cloneInitial(): MachineSettingsForm {
  return {
    location_lat: props.initial.location_lat ?? null,
    location_lon: props.initial.location_lon ?? null,
    address_street: props.initial.address_street ?? null,
    address_house_number: props.initial.address_house_number ?? null,
    address_postal_code: props.initial.address_postal_code ?? null,
    address_city: props.initial.address_city ?? null,
    formatted_address: props.initial.formatted_address ?? null,
    country_code: props.initial.country_code ?? null,
    nayax_machine_id: props.initial.nayax_machine_id ?? null,
    item_number_offset: props.initial.item_number_offset ?? 0,
    linked_selections: props.initial.linked_selections ?? false,
    temp_sensors: parseTempSettings(props.initial.temp_sensors),
  }
}

async function generatePublicQr() {
  if (!publicUrl.value) return
  try {
    publicQrDataUrl.value = await QRCode.toDataURL(publicUrl.value, {
      width: 256,
      margin: 2,
      errorCorrectionLevel: 'M',
    })
  } catch (err) {
    console.error('QR code generation failed:', err)
  }
}

async function togglePublicListing() {
  const newValue = !publicListingValue.value
  publicListingLoading.value = true
  publicListingError.value = ''
  const prevValue = publicListingValue.value
  publicListingValue.value = newValue
  try {
    const { error } = await supabase
      .from('vendingMachine')
      .update({ public_listing: newValue } as any)
      .eq('id', props.machineId)
    if (error) throw error
    if (newValue) {
      await generatePublicQr()
    } else {
      publicQrDataUrl.value = ''
    }
    emit('saved')
  } catch (err: unknown) {
    publicListingValue.value = prevValue
    publicListingError.value = err instanceof Error ? err.message : t('machineDetail.failedToUpdate')
  } finally {
    publicListingLoading.value = false
  }
}

async function copyPublicUrl() {
  if (!publicUrl.value) return
  try {
    await navigator.clipboard.writeText(publicUrl.value)
    publicUrlCopied.value = true
    setTimeout(() => { publicUrlCopied.value = false }, 2000)
  } catch (err) {
    console.error('Copy failed:', err)
  }
}

function downloadQrCode() {
  if (!publicQrDataUrl.value || !props.machineId) return
  const link = document.createElement('a')
  link.href = publicQrDataUrl.value
  link.download = `machine-${props.machineId.substring(0, 8)}.png`
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
}

onMounted(() => {
  publicPageOrigin.value = window.location.origin
})

// Reset the form every time the modal opens fresh
watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      form.value = cloneInitial()
      errorMsg.value = null
      publicListingValue.value = props.publicListing
      publicListingError.value = ''
      if (publicListingValue.value && publicPageOrigin.value && !publicQrDataUrl.value) {
        generatePublicQr()
      }
      loadContact()
    }
  },
)

// Keep internal value in sync if parent updates the prop while closed
watch(() => props.publicListing, (v) => {
  if (!props.open) publicListingValue.value = v
})

async function save() {
  saving.value = true
  errorMsg.value = null
  try {
    if (form.value.nayax_machine_id === '') form.value.nayax_machine_id = null
    // An emptied number input yields '' / NaN; the column is NOT NULL.
    const parsedOffset = Number(form.value.item_number_offset)
    form.value.item_number_offset = Number.isFinite(parsedOffset) ? Math.trunc(parsedOffset) : 0
    await updateMachineSettings(props.machineId, {
      ...form.value,
      temp_sensors: cleanTempSettings(form.value.temp_sensors),
    } as MachineSettingsPatch)
    await saveContact()
    emit('saved')
    emit('update:open', false)
  } catch (err) {
    errorMsg.value = (err as Error).message ?? 'Unknown error'
  } finally {
    saving.value = false
  }
}

function clearLocation() {
  form.value.location_lat = null
  form.value.location_lon = null
  form.value.address_street = null
  form.value.address_house_number = null
  form.value.address_postal_code = null
  form.value.address_city = null
  form.value.formatted_address = null
  form.value.country_code = null
}

function cancel() {
  emit('update:open', false)
}
</script>

<template>
  <Dialog :open="open" @update:open="(v) => emit('update:open', v)">
    <DialogContent class="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
      <DialogHeader>
        <DialogTitle>{{ t('machineSettings.title') }}</DialogTitle>
      </DialogHeader>

      <div class="flex flex-col gap-4 py-2">
        <ClientOnly>
          <LocationPicker v-model="form" />
          <template #fallback>
            <div class="flex h-[200px] w-full items-center justify-center rounded-md border border-dashed text-sm text-muted-foreground">
              {{ t('machineSettings.mapLoading') }}
            </div>
          </template>
        </ClientOnly>

        <!-- Country code override -->
        <div>
          <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.country') }}</label>
          <select
            v-model="form.country_code"
            class="mt-1 h-9 w-full rounded-md border border-input bg-background px-3 text-sm shadow-sm focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          >
            <option :value="null">—</option>
            <option v-for="c in COUNTRY_OPTIONS" :key="c.code" :value="c.code">
              {{ c.code }} — {{ c.label }}
            </option>
          </select>
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.countryAutoHint') }}</p>
        </div>

        <!-- Nayax machine ID -->
        <div class="space-y-1">
          <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.nayaxMachineId') }}</label>
          <input
            v-model="form.nayax_machine_id"
            type="text"
            inputmode="numeric"
            :placeholder="t('machineSettings.nayaxMachineIdPlaceholder')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.nayaxMachineIdHint') }}</p>
        </div>

        <!-- MDB slot number offset -->
        <div class="space-y-1">
          <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.itemNumberOffset') }}</label>
          <input
            v-model.number="form.item_number_offset"
            type="number"
            step="1"
            inputmode="numeric"
            :placeholder="t('machineSettings.itemNumberOffsetPlaceholder')"
            class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
          />
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.itemNumberOffsetHint') }}</p>
          <p v-if="form.item_number_offset !== 0" class="mt-1 rounded bg-amber-500/10 px-2 py-1 text-[10px] text-amber-700 dark:text-amber-400">
            {{ t('machineSettings.itemNumberOffsetWarning') }}
          </p>
        </div>

        <!-- Linked selections: the machine vends from a sibling slot when one is empty -->
        <label for="machine-linked-selections" class="flex cursor-pointer items-start gap-3">
          <input
            id="machine-linked-selections"
            v-model="form.linked_selections"
            type="checkbox"
            class="mt-0.5 h-4 w-4 shrink-0 rounded border-input accent-primary"
          />
          <span class="space-y-0.5">
            <span class="block text-xs font-medium">{{ t('machineSettings.linkedSelections') }}</span>
            <span class="block text-[10px] text-muted-foreground">{{ t('machineSettings.linkedSelectionsHint') }}</span>
          </span>
        </label>

        <!-- Temperature sensors: names + which ones show next to the machine name -->
        <TemperatureSensorsSettings
          v-model="form.temp_sensors"
          :readings="tempReadings ?? []"
        />

        <!-- ── Contact overrides for printed posters ─────────── -->
        <div class="rounded-xl border bg-card p-4">
          <button
            type="button"
            class="flex w-full items-center justify-between text-left"
            @click="contactOpen = !contactOpen"
          >
            <span>
              <span class="text-sm font-medium">{{ t('machineSettings.contactOverrides') }}</span>
              <span v-if="hasContactOverride" class="ml-2 rounded bg-primary/10 px-1.5 py-0.5 text-[10px] text-primary">
                {{ t('machineSettings.contactOverrideActive') }}
              </span>
            </span>
            <span class="text-xs text-muted-foreground">{{ contactOpen ? '−' : '+' }}</span>
          </button>
          <p class="mt-1 text-[10px] text-muted-foreground">{{ t('machineSettings.contactOverridesHint') }}</p>

          <div v-if="contactOpen" class="mt-3 grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div class="space-y-1">
              <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.contactPhone') }}</label>
              <input
                v-model="contact.contact_phone"
                type="tel"
                :placeholder="companyContact.contact_phone || '—'"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.contactWhatsapp') }}</label>
              <input
                v-model="contact.whatsapp_phone"
                type="tel"
                :placeholder="companyContact.whatsapp_phone || '—'"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.contactHours') }}</label>
              <input
                v-model="contact.support_hours"
                type="text"
                :placeholder="companyContact.support_hours || '—'"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
            <div class="space-y-1">
              <label class="text-xs font-medium text-muted-foreground">{{ t('machineSettings.contactEmail') }}</label>
              <input
                v-model="contact.contact_email"
                type="email"
                :placeholder="companyContact.contact_email || '—'"
                class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring"
              />
            </div>
          </div>
        </div>

        <p v-if="errorMsg" class="text-xs text-destructive">{{ errorMsg }}</p>

        <!-- ── Public Visibility ─────────────────────────────── -->
        <div class="rounded-xl border bg-card p-4">
          <div class="mb-4 flex items-center gap-2">
            <svg class="size-5 text-primary" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
              <path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 010-.639C3.423 7.51 7.36 4.5 12 4.5c4.638 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.638 0-8.573-3.007-9.963-7.178z" />
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
            </svg>
            <h2 class="text-base font-semibold">{{ t('machineDetail.publicVisibility') }}</h2>
          </div>

          <!-- Toggle row -->
          <div class="mb-4 flex items-center justify-between gap-4">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-medium">{{ t('machineDetail.publicListingToggle') }}</p>
              <p class="text-xs text-muted-foreground">{{ t('machineDetail.publicListingDescription') }}</p>
            </div>
            <button
              type="button"
              role="switch"
              :aria-checked="publicListingValue"
              :disabled="publicListingLoading"
              class="relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50"
              :class="publicListingValue ? 'bg-primary' : 'bg-input'"
              @click="togglePublicListing"
            >
              <span
                class="pointer-events-none inline-block size-5 translate-y-0 rounded-full bg-background shadow-lg ring-0 transition-transform"
                :class="publicListingValue ? 'translate-x-5' : 'translate-x-0'"
              />
            </button>
          </div>
          <p v-if="publicListingError" class="mb-3 text-xs text-destructive">{{ publicListingError }}</p>

          <!-- URL (always shown) -->
          <div class="mb-4 space-y-1">
            <label class="text-xs font-medium text-muted-foreground">{{ t('machineDetail.publicUrl') }}</label>
            <div class="flex items-center gap-2 rounded-lg border bg-muted/50 px-3 py-2">
              <code class="flex-1 truncate font-mono text-xs">{{ publicUrl || '—' }}</code>
              <button
                type="button"
                class="shrink-0 text-muted-foreground hover:text-foreground disabled:opacity-50"
                :disabled="!publicUrl"
                :title="publicUrlCopied ? t('common.copied') : t('common.copy')"
                @click="copyPublicUrl"
              >
                <svg v-if="!publicUrlCopied" class="size-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M15.75 17.25v3.375c0 .621-.504 1.125-1.125 1.125h-9.75a1.125 1.125 0 01-1.125-1.125V7.875c0-.621.504-1.125 1.125-1.125H6.75a9.06 9.06 0 011.5.124m7.5 10.376h3.375c.621 0 1.125-.504 1.125-1.125V11.25c0-4.46-3.243-8.161-7.5-8.876a9.06 9.06 0 00-1.5-.124H9.375c-.621 0-1.125.504-1.125 1.125v3.5m7.5 10.375H9.375a1.125 1.125 0 01-1.125-1.125v-9.25m12 6.625v-1.875a3.375 3.375 0 00-3.375-3.375h-1.5a1.125 1.125 0 01-1.125-1.125v-1.5a3.375 3.375 0 00-3.375-3.375H9.75" />
                </svg>
                <svg v-else class="size-4 text-emerald-500" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                  <path stroke-linecap="round" stroke-linejoin="round" d="M4.5 12.75l6 6 9-13.5" />
                </svg>
              </button>
            </div>
          </div>

          <!-- QR Code or disabled hint -->
          <template v-if="publicListingValue">
            <div class="space-y-2">
              <label class="text-xs font-medium text-muted-foreground">{{ t('machineDetail.qrCode') }}</label>
              <div class="flex flex-col items-center gap-3 rounded-lg border bg-white p-4 sm:flex-row sm:items-start">
                <img
                  v-if="publicQrDataUrl"
                  :src="publicQrDataUrl"
                  :alt="t('machineDetail.qrCode')"
                  class="size-32 shrink-0 sm:size-40"
                />
                <div v-else class="flex size-32 shrink-0 items-center justify-center bg-muted sm:size-40">
                  <div class="size-5 animate-spin rounded-full border-2 border-muted-foreground border-t-primary" />
                </div>
                <div class="flex flex-1 flex-col items-center gap-2 sm:items-start sm:justify-between sm:self-stretch">
                  <p class="text-center text-xs text-muted-foreground sm:text-left">
                    {{ t('machineDetail.qrCodeHint') }}
                  </p>
                  <button
                    class="inline-flex items-center gap-1.5 rounded-md bg-primary px-3 py-1.5 text-xs font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90 disabled:opacity-50"
                    :disabled="!publicQrDataUrl"
                    @click="downloadQrCode"
                  >
                    <svg class="size-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                      <path stroke-linecap="round" stroke-linejoin="round" d="M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" />
                    </svg>
                    {{ t('machineDetail.downloadQr') }}
                  </button>
                </div>
              </div>
            </div>
          </template>
          <template v-else>
            <div class="rounded-lg border border-dashed bg-muted/30 px-4 py-3">
              <p class="text-xs text-muted-foreground">{{ t('machineDetail.publicListingDisabledHint') }}</p>
            </div>
          </template>
        </div>
      </div>

      <DialogFooter class="flex items-center justify-between gap-2 sm:justify-between">
        <button
          v-if="form.location_lat != null"
          type="button"
          class="inline-flex items-center gap-1 text-xs text-destructive hover:underline"
          :disabled="saving"
          @click="clearLocation"
        >
          <IconTrash class="size-3.5" />
          {{ t('machineSettings.clearLocation') }}
        </button>
        <div v-else />
        <div class="flex gap-2">
          <button
            type="button"
            class="h-9 rounded-md border border-input bg-background px-4 text-sm font-medium shadow-sm hover:bg-accent"
            :disabled="saving"
            @click="cancel"
          >
            {{ t('machineSettings.cancel') }}
          </button>
          <button
            type="button"
            class="h-9 rounded-md bg-primary px-4 text-sm font-medium text-primary-foreground shadow hover:bg-primary/90 disabled:opacity-50"
            :disabled="saving"
            @click="save"
          >
            {{ t('machineSettings.save') }}
          </button>
        </div>
      </DialogFooter>
    </DialogContent>
  </Dialog>
</template>
