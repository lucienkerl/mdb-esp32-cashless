<script setup lang="ts">
import QRCode from 'qrcode'
import { computeSoftApSsid, formatWifiQrPayload } from '@/lib/softap'

interface Props {
  open: boolean
  device: {
    id: string
    mac_address: string | null
    subdomain: number | null
    softap_password: string | null
  } | null
}

const props = defineProps<Props>()
const emit = defineEmits<{ (e: 'close'): void }>()

const { t } = useI18n()

const ssid = computed(() => computeSoftApSsid(props.device?.mac_address ?? null))
// "Open AP" state: device hasn't been claimed against the new backend yet, so
// no password has been assigned. The frontend treats this as a distinct state
// (not "the password is empty string") so the UI can render guidance instead
// of trying to copy/show an empty string.
const isOpenAp = computed(() => !props.device?.softap_password)
const password = computed(() => props.device?.softap_password ?? '')

const passwordVisible = ref(false)
const copied = ref(false)
const qrDataUrl = ref('')

watch(
  () => [props.open, ssid.value, password.value, isOpenAp.value],
  async ([isOpen, , , openMode]) => {
    if (!isOpen) {
      qrDataUrl.value = ''
      return
    }
    // QR encodes T:nopass for open networks (per the WPA QR de-facto spec).
    const payload = openMode
      ? `WIFI:T:nopass;S:${ssid.value};;`
      : formatWifiQrPayload(ssid.value, password.value)
    qrDataUrl.value = await QRCode.toDataURL(payload, { width: 240, margin: 2 })
  },
  { immediate: true },
)

watch(() => props.open, (o) => {
  if (!o) {
    passwordVisible.value = false
    copied.value = false
  }
})

async function copyPassword() {
  if (!password.value) return
  try {
    await navigator.clipboard.writeText(password.value)
    copied.value = true
    setTimeout(() => { copied.value = false }, 1500)
  } catch {
    // Clipboard API unavailable (HTTP, no permission). Silent.
  }
}
</script>

<template>
  <AppModal :open="open" :title="t('softap.title')" @update:open="(v) => { if (!v) emit('close') }">
    <div v-if="!device" class="text-sm text-muted-foreground">
      {{ t('common.loading') }}
    </div>
    <div v-else class="space-y-4">
      <!-- Open-AP banner -->
      <div
        v-if="isOpenAp"
        class="rounded-md border border-amber-500/40 bg-amber-500/10 p-3 text-xs text-amber-700 dark:text-amber-300"
      >
        <p class="font-medium">{{ t('softap.openAp') }}</p>
        <p class="mt-1">{{ t('softap.openApHint') }}</p>
      </div>

      <!-- SSID -->
      <div>
        <p class="text-xs font-medium text-muted-foreground">{{ t('softap.ssid') }}</p>
        <p class="mt-1 font-mono text-base">{{ ssid }}</p>
      </div>

      <!-- Password (only when assigned) -->
      <div v-if="!isOpenAp">
        <p class="text-xs font-medium text-muted-foreground">{{ t('softap.password') }}</p>
        <div class="mt-1 flex items-center gap-2">
          <p class="flex-1 font-mono text-base">
            <template v-if="passwordVisible">{{ password }}</template>
            <template v-else>••••••••••••</template>
          </p>
          <button
            type="button"
            class="inline-flex h-7 items-center rounded-md border px-2 text-xs hover:bg-muted"
            @click="passwordVisible = !passwordVisible"
          >
            {{ passwordVisible ? t('softap.hide') : t('softap.reveal') }}
          </button>
          <button
            type="button"
            class="inline-flex h-7 items-center rounded-md border px-2 text-xs hover:bg-muted"
            @click="copyPassword"
          >
            {{ copied ? t('softap.copied') : t('softap.copy') }}
          </button>
        </div>
      </div>

      <!-- QR (always rendered — works for both open and WPA2) -->
      <div v-if="qrDataUrl" class="flex flex-col items-center gap-2 pt-2">
        <img :src="qrDataUrl" :alt="ssid" class="rounded-md border bg-white p-2" width="240" height="240" />
        <p class="text-xs text-muted-foreground">{{ t('softap.qrHelp') }}</p>
      </div>
    </div>
  </AppModal>
</template>
