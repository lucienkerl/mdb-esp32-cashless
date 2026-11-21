<script setup lang="ts">
import {
  IconBell,
  IconCash,
  IconInbox,
  IconMail,
  IconPackage,
  IconSend,
  IconTag,
  IconWifi,
  IconWifiOff,
} from '@tabler/icons-vue'
import { Switch } from '~/components/ui/switch'
import { NOTIFICATION_CHANNELS, NOTIFICATION_EVENT_TYPES, type NotificationChannel } from '~/lib/notificationSettings'

const { t } = useI18n()
const { channels, loading, error, saving, load, isEnabled, channel, setEnabled, sendTestEmail } =
  useNotificationSettings()

onMounted(() => { load() })

const typeIcons = {
  cash: IconCash,
  package: IconPackage,
  'wifi-off': IconWifiOff,
  wifi: IconWifi,
  inbox: IconInbox,
  tag: IconTag,
} as const

const channelIcons: Record<NotificationChannel, typeof IconBell> = {
  push: IconBell,
  email: IconMail,
}

const email = computed(() => channel('email'))
const push = computed(() => channel('push'))

function cellDisabled(key: NotificationChannel): boolean {
  if (key === 'email') return !email.value?.available
  return false
}

// ── Test email ───────────────────────────────────────────────────────────────
const testLoading = ref(false)
const testResult = ref('')
const testOk = ref(false)

async function handleTestEmail() {
  testLoading.value = true
  testResult.value = ''
  const res = await sendTestEmail()
  testOk.value = res.ok
  testResult.value = res.ok
    ? t('settings.notifMatrix.testEmailSent', { address: res.address ?? email.value?.address ?? '' })
    : t('settings.notifMatrix.testEmailFailed', { error: res.message ?? '' })
  testLoading.value = false
}
</script>

<template>
  <ClientOnly>
    <div class="rounded-xl border bg-card p-6 shadow-sm">
      <h2 class="mb-1 text-lg font-semibold">{{ t('settings.notifMatrix.title') }}</h2>
      <p class="mb-5 text-sm text-muted-foreground">{{ t('settings.notifMatrix.description') }}</p>

      <div
        v-if="error"
        class="mb-4 rounded-lg border border-destructive/20 bg-destructive/5 p-3 text-sm text-destructive"
      >
        {{ error }}
      </div>

      <div class="overflow-hidden rounded-lg border" :class="loading ? 'opacity-60' : ''">
        <table class="w-full table-fixed text-sm">
          <thead class="bg-muted/50">
            <tr>
              <th class="px-3 py-2 text-left font-medium text-muted-foreground">
                {{ t('settings.notifMatrix.event') }}
              </th>
              <th
                v-for="ch in NOTIFICATION_CHANNELS"
                :key="ch"
                class="w-14 px-1 py-2 text-center font-medium text-muted-foreground sm:w-24 sm:px-2"
              >
                <span class="inline-flex flex-col items-center gap-0.5 sm:flex-row sm:gap-1.5">
                  <component :is="channelIcons[ch]" class="size-4" />
                  <span class="text-xs sm:text-sm">{{ t(`settings.notifMatrix.channels.${ch}`) }}</span>
                </span>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="nt in NOTIFICATION_EVENT_TYPES" :key="nt.key" class="border-t">
              <td class="px-3 py-3 align-top">
                <div class="flex items-start gap-2.5">
                  <component :is="typeIcons[nt.icon]" class="mt-0.5 hidden size-4 shrink-0 text-muted-foreground sm:block" />
                  <div class="min-w-0 space-y-0.5 hyphens-auto [overflow-wrap:anywhere]">
                    <p class="font-medium">{{ t(`settings.notifTypes.${nt.key}.label`) }}</p>
                    <p class="text-xs text-muted-foreground">{{ t(`settings.notifTypes.${nt.key}.description`) }}</p>
                  </div>
                </div>
              </td>
              <td v-for="ch in NOTIFICATION_CHANNELS" :key="ch" class="px-1 py-3 text-center align-middle sm:px-2">
                <Switch
                  :checked="isEnabled(nt.key, ch)"
                  :disabled="cellDisabled(ch) || saving === `${nt.key}:${ch}`"
                  :aria-label="`${t(`settings.notifTypes.${nt.key}.label`)} – ${t(`settings.notifMatrix.channels.${ch}`)}`"
                  @update:checked="(val: boolean) => setEnabled(nt.key, ch, val)"
                />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <!-- Channel notes -->
      <div class="mt-4 space-y-3 text-sm">
        <p v-if="push && !push.available" class="text-muted-foreground">
          {{ t('settings.notifMatrix.pushUnavailable') }}
        </p>
        <p v-else class="text-muted-foreground">{{ t('settings.notifMatrix.pushHint') }}</p>

        <p v-if="email && !email.configured" class="text-muted-foreground">
          {{ t('settings.notifMatrix.emailNotConfigured') }}
        </p>
        <p v-else-if="email && !email.address" class="text-muted-foreground">
          {{ t('settings.notifMatrix.emailNoAddress') }}
        </p>
        <div v-else-if="email" class="flex flex-wrap items-center justify-between gap-3">
          <p class="min-w-0 text-muted-foreground">
            {{ t('settings.notifMatrix.emailGoesTo') }}
            <span class="font-medium text-foreground break-all">{{ email.address }}</span>
          </p>
          <button
            :disabled="testLoading"
            class="inline-flex h-9 shrink-0 items-center gap-1.5 rounded-md border border-input bg-background px-3 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
            @click="handleTestEmail"
          >
            <IconSend class="size-3.5" />
            <span v-if="testLoading">{{ t('settings.sending') }}</span>
            <span v-else>{{ t('settings.notifMatrix.sendTestEmail') }}</span>
          </button>
        </div>
        <p v-if="testResult" :class="testOk ? 'text-emerald-600 dark:text-emerald-400' : 'text-destructive'">
          {{ testResult }}
        </p>
      </div>
    </div>
  </ClientOnly>
</template>
