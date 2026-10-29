<script setup lang="ts">
import { IconBell, IconBellOff, IconDeviceMobile, IconSend, IconTrash } from '@tabler/icons-vue'
import { Switch } from '~/components/ui/switch'
import { notificationTypes } from '~/composables/useNotifications'
import { timeAgo } from '~/lib/utils'

const { t } = useI18n()
const supabase = useSupabaseClient()

const {
  permission: notifPermission,
  isSubscribed,
  isSupported: pushSupported,
  needsHomescreen,
  isIOS,
  loading: notifLoading,
  error: notifError,
  subscribe: subscribePush,
  unsubscribe: unsubscribePush,
  devices,
  isTypeEnabled,
  togglePreference,
  removeDevice,
  init: initNotifications,
} = useNotifications()

// Initialize notifications on client mount
onMounted(() => { initNotifications() })

// ── Service Worker diagnostics ───────────────────────────────────────────────
const swStatus = ref('')
const swDiagLoading = ref(false)

async function checkSwStatus() {
  if (import.meta.server) return
  swDiagLoading.value = true
  const lines: string[] = []

  try {
    // 1. API support
    const hasSW = 'serviceWorker' in navigator
    const hasPM = 'PushManager' in window
    const hasNotif = 'Notification' in window
    lines.push(`APIs: SW=${hasSW} Push=${hasPM} Notif=${hasNotif}`)

    // 2. Protocol & context
    lines.push(`Protocol: ${location.protocol}`)
    lines.push(`Standalone: ${window.matchMedia('(display-mode: standalone)').matches || (navigator as any).standalone === true}`)
    lines.push(`Host: ${location.host}`)

    if (!hasSW) {
      lines.push('⛔ ServiceWorker API missing')
      swStatus.value = lines.join('\n')
      return
    }

    // 3. Current controller
    const ctrl = navigator.serviceWorker.controller
    lines.push(`Controller: ${ctrl ? `${ctrl.state} (${ctrl.scriptURL})` : 'none'}`)

    // 4. All registrations
    const regs = await navigator.serviceWorker.getRegistrations()
    lines.push(`Registrations: ${regs.length}`)
    for (const reg of regs) {
      const active = reg.active
      const waiting = reg.waiting
      const installing = reg.installing
      lines.push(`  scope: ${reg.scope}`)
      if (active) lines.push(`    active: ${active.state} ${active.scriptURL}`)
      if (waiting) lines.push(`    waiting: ${waiting.state}`)
      if (installing) lines.push(`    installing: ${installing.state}`)
      if (!active && !waiting && !installing) lines.push(`    (no worker)`)
    }

    // 5. If no registrations, try to manually register and see what happens
    if (regs.length === 0) {
      lines.push('⚠️ No SW registered. Attempting manual registration…')
      try {
        const reg = await navigator.serviceWorker.register('/sw.js', { scope: '/', updateViaCache: 'none' })
        const sw = reg.installing ?? reg.waiting ?? reg.active
        lines.push(`✅ Manual register OK: ${sw?.state ?? 'unknown'}`)
      } catch (regErr: any) {
        lines.push(`❌ Manual register failed: ${regErr.message}`)
      }
    }

    // 6. Notification permission
    if (hasNotif) {
      lines.push(`Notif permission: ${Notification.permission}`)
    }

    // 7. Check if SW script is reachable
    try {
      const resp = await fetch('/sw.js', { method: 'HEAD' })
      lines.push(`SW file /sw.js: ${resp.status} ${resp.ok ? '✅' : '❌'}`)
    } catch (fetchErr: any) {
      lines.push(`SW file /sw.js: fetch failed (${fetchErr.message})`)
    }
  } catch (e: any) {
    lines.push(`Diagnostic error: ${e.message}`)
  } finally {
    swStatus.value = lines.join('\n')
    swDiagLoading.value = false
  }
}

onMounted(() => { if (import.meta.client) checkSwStatus() })

// Toggle master push subscription
async function handlePushToggle(enabled: boolean) {
  if (enabled) {
    await subscribePush()
  } else {
    await unsubscribePush()
  }
}

// ── Test notification ─────────────────────────────────────────────────────────
const testLoading = ref(false)
const testResult = ref('')

async function sendTestNotification() {
  testResult.value = ''
  testLoading.value = true
  try {
    const { data, error } = await supabase.functions.invoke('test-push')
    if (error) throw error
    const sent = data?.sent ?? 0
    if (sent > 0) {
      testResult.value = t('settings.testNotificationSent', { count: sent }, sent)
    } else {
      testResult.value = t('settings.noSubscriptions')
    }
  } catch (err: unknown) {
    testResult.value = err instanceof Error ? err.message : t('settings.testNotificationFailed')
  } finally {
    testLoading.value = false
  }
}

// ── Push device helpers ──────────────────────────────────────────────────────
function parseDeviceInfo(device: { endpoint: string; user_agent: string | null }) {
  // Detect push service from endpoint
  let service = 'Unknown'
  if (device.endpoint.includes('fcm.googleapis.com') || device.endpoint.includes('google')) service = 'Chrome'
  else if (device.endpoint.includes('mozilla.com')) service = 'Firefox'
  else if (device.endpoint.includes('apple.com')) service = 'Safari'
  else if (device.endpoint.includes('notify.windows.com')) service = 'Edge'

  // Parse user agent for OS
  const ua = device.user_agent ?? ''
  let os = ''
  if (/Android/i.test(ua)) os = 'Android'
  else if (/iPhone|iPad|iPod/i.test(ua)) os = 'iOS'
  else if (/Mac OS X|macOS/i.test(ua)) os = 'macOS'
  else if (/Windows/i.test(ua)) os = 'Windows'
  else if (/Linux/i.test(ua)) os = 'Linux'

  const label = os ? `${service} on ${os}` : service
  return { label, service, os }
}
</script>

<template>
  <!-- Push Notifications -->
  <ClientOnly>
    <div class="rounded-xl border bg-card p-6 shadow-sm">
      <div class="mb-5 flex items-center gap-2">
        <IconBell v-if="isSubscribed" class="size-5 text-primary" />
        <IconBellOff v-else class="size-5 text-muted-foreground" />
        <div>
          <h2 class="text-lg font-semibold">{{ t('settings.pushNotifications') }}</h2>
          <p class="text-sm text-muted-foreground">
            {{ t('settings.pushDescription') }}
          </p>
        </div>
      </div>

      <!-- iOS homescreen guidance -->
      <div
        v-if="needsHomescreen"
        class="mb-5 flex items-start gap-3 rounded-lg border border-amber-200 bg-amber-50 p-4 dark:border-amber-900 dark:bg-amber-950"
      >
        <IconDeviceMobile class="mt-0.5 size-5 shrink-0 text-amber-600 dark:text-amber-400" />
        <div class="text-sm">
          <p class="mb-1 font-medium text-amber-800 dark:text-amber-200">
            {{ t('settings.addToHomeScreen') }}
          </p>
          <p class="text-amber-700 dark:text-amber-300">
            {{ t('settings.iosGuidance') }}
          </p>
        </div>
      </div>

      <!-- Not supported warning -->
      <div
        v-if="!pushSupported && !needsHomescreen"
        class="mb-5 rounded-lg border border-muted bg-muted/50 p-4 text-sm text-muted-foreground"
      >
        {{ t('settings.browserNotSupported') }}
      </div>

      <!-- Permission denied warning -->
      <div
        v-if="notifPermission === 'denied'"
        class="mb-5 rounded-lg border border-destructive/20 bg-destructive/5 p-4 text-sm text-destructive"
      >
        <template v-if="isIOS">
          {{ t('settings.notificationsBlocked') }}
        </template>
        <template v-else>
          {{ t('settings.permissionDenied') }}
        </template>
      </div>

      <!-- Error message -->
      <div
        v-if="notifError"
        class="mb-5 rounded-lg border border-destructive/20 bg-destructive/5 p-4 text-sm text-destructive"
      >
        {{ notifError }}
      </div>

      <!-- Master toggle -->
      <div class="flex items-center justify-between">
        <div class="space-y-0.5">
          <label class="text-sm font-medium">
            {{ t('settings.enableOnDevice') }}
          </label>
          <p class="text-sm text-muted-foreground">
            <template v-if="notifLoading">{{ t('settings.activating') }}</template>
            <template v-else>{{ isSubscribed ? t('settings.notificationsActive') : t('settings.notificationsOff') }}</template>
          </p>
        </div>
        <Switch
          :checked="isSubscribed"
          :disabled="notifLoading || !pushSupported || notifPermission === 'denied' || needsHomescreen"
          @update:checked="handlePushToggle"
        />
      </div>

      <!-- Per-type toggles (only visible when subscribed) -->
      <div v-if="isSubscribed" class="mt-6 space-y-4 border-t pt-5">
        <h3 class="text-sm font-medium text-muted-foreground">{{ t('settings.notificationTypes') }}</h3>

        <div
          v-for="nt in notificationTypes"
          :key="nt.key"
          class="flex items-center justify-between"
        >
          <div class="space-y-0.5">
            <label class="text-sm font-medium">{{ t(`settings.notifTypes.${nt.key}.label`) }}</label>
            <p class="text-sm text-muted-foreground">{{ t(`settings.notifTypes.${nt.key}.description`) }}</p>
          </div>
          <Switch
            :checked="isTypeEnabled(nt.key)"
            @update:checked="(val: boolean) => togglePreference(nt.key, val)"
          />
        </div>

        <!-- Test notification -->
        <div class="flex items-center justify-between pt-2">
          <div class="space-y-0.5">
            <label class="text-sm font-medium">{{ t('settings.testNotificationLabel') }}</label>
            <p class="text-sm text-muted-foreground">
              {{ testResult || t('settings.testNotificationDescription') }}
            </p>
          </div>
          <button
            :disabled="testLoading"
            class="inline-flex h-9 items-center gap-1.5 rounded-md border border-input bg-background px-3 text-sm font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
            @click="sendTestNotification"
          >
            <IconSend class="size-3.5" />
            <span v-if="testLoading">{{ t('settings.sending') }}</span>
            <span v-else>{{ t('settings.sendTest') }}</span>
          </button>
        </div>

        <!-- Registered devices -->
        <div v-if="devices.length > 0" class="mt-2 pt-4 border-t">
          <h3 class="text-sm font-medium text-muted-foreground mb-3">{{ t('settings.registeredDevices') }}</h3>
          <div class="space-y-2">
            <div
              v-for="device in devices"
              :key="device.id"
              class="flex items-center justify-between rounded-lg border px-3 py-2"
            >
              <div class="min-w-0">
                <p class="text-sm font-medium truncate">{{ parseDeviceInfo(device).label }}</p>
                <p class="text-xs text-muted-foreground">
                  {{ t('settings.registered', { time: timeAgo(device.created_at, t) }) }}
                </p>
              </div>
              <button
                class="ml-2 shrink-0 inline-flex h-7 w-7 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-destructive/10 hover:text-destructive"
                :title="t('settings.removeDevice')"
                @click="removeDevice(device.id)"
              >
                <IconTrash class="size-3.5" />
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Service Worker Diagnostics -->
      <div class="mt-6 border-t pt-5">
        <div class="flex items-center justify-between mb-3">
          <h3 class="text-sm font-medium text-muted-foreground">{{ t('settings.swDiagnostics') }}</h3>
          <button
            :disabled="swDiagLoading"
            class="inline-flex h-7 items-center gap-1 rounded-md border border-input bg-background px-2 text-xs font-medium shadow-sm transition-colors hover:bg-muted disabled:opacity-50"
            @click="checkSwStatus"
          >
            <span v-if="swDiagLoading">{{ t('settings.checking') }}</span>
            <span v-else>{{ t('settings.recheck') }}</span>
          </button>
        </div>
        <pre
          v-if="swStatus"
          class="whitespace-pre-wrap rounded-lg border bg-muted/50 p-3 text-xs font-mono text-muted-foreground leading-relaxed"
        >{{ swStatus }}</pre>
        <p v-else class="text-xs text-muted-foreground">{{ t('settings.loadingDiagnostics') }}</p>
      </div>
    </div>
  </ClientOnly>
</template>
