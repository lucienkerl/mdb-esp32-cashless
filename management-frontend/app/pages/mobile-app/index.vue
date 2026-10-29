<script setup lang="ts">
import QRCode from 'qrcode'

definePageMeta({ middleware: 'auth' })

const { t } = useI18n()
const config = useRuntimeConfig()

// Get the Supabase URL and anon key for the QR code
const supabaseUrl = config.public.supabase.url as string
const supabaseKey = config.public.supabase.key as string

const qrPayload = JSON.stringify({
  v: 1,
  url: supabaseUrl,
  anonKey: supabaseKey,
})

const copiedField = ref<string | null>(null)

const qrSvg = ref('')

onMounted(async () => {
  try {
    qrSvg.value = await QRCode.toString(qrPayload, {
      type: 'svg',
      width: 280,
      margin: 2,
      color: { dark: '#000000', light: '#ffffff' },
    })
  } catch (e) {
    console.error('[mobile-app] QR generation failed:', e)
  }
})

async function copyToClipboard(text: string, field: string) {
  await navigator.clipboard.writeText(text)
  copiedField.value = field
  setTimeout(() => { copiedField.value = null }, 2000)
}
</script>

<template>
  <div class="mx-auto max-w-lg space-y-8 py-8 px-4">
    <div>
      <h1 class="text-2xl font-bold tracking-tight">{{ t('mobileApp.title') }}</h1>
      <p class="mt-1 text-muted-foreground">{{ t('mobileApp.description') }}</p>
    </div>

    <!-- Steps -->
    <ol class="list-inside list-decimal space-y-3 text-sm">
      <li>{{ t('mobileApp.step1') }}</li>
      <li>{{ t('mobileApp.step2') }}</li>
      <li>{{ t('mobileApp.step3') }}</li>
    </ol>

    <!-- QR Code -->
    <div class="flex justify-center rounded-lg border bg-white p-6">
      <div v-if="qrSvg" v-html="qrSvg" class="h-[280px] w-[280px]" />
      <div v-else class="flex h-[280px] w-[280px] items-center justify-center">
        <div class="text-muted-foreground">{{ t('common.loading') }}</div>
      </div>
    </div>

    <!-- Manual entry -->
    <div class="space-y-4">
      <p class="text-center text-sm text-muted-foreground">{{ t('mobileApp.orManual') }}</p>

      <div class="space-y-3">
        <div>
          <label class="text-xs font-medium text-muted-foreground uppercase">{{ t('mobileApp.supabaseUrl') }}</label>
          <div
            class="mt-1 flex cursor-pointer items-center justify-between rounded-md border bg-muted/50 px-3 py-2 text-sm font-mono"
            @click="copyToClipboard(supabaseUrl, 'url')"
          >
            <span class="truncate">{{ supabaseUrl }}</span>
            <span v-if="copiedField === 'url'" class="ml-2 text-xs text-green-600 shrink-0">{{ t('mobileApp.copied') }}</span>
          </div>
        </div>

        <div>
          <label class="text-xs font-medium text-muted-foreground uppercase">{{ t('mobileApp.anonKey') }}</label>
          <div
            class="mt-1 flex cursor-pointer items-center justify-between rounded-md border bg-muted/50 px-3 py-2 text-sm font-mono"
            @click="copyToClipboard(supabaseKey, 'key')"
          >
            <span class="truncate">{{ supabaseKey }}</span>
            <span v-if="copiedField === 'key'" class="ml-2 text-xs text-green-600 shrink-0">{{ t('mobileApp.copied') }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
