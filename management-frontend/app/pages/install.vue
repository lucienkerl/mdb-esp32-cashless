<script setup lang="ts">
definePageMeta({ layout: false })

const { t } = useI18n()

// Fetch public firmware versions
const { data: versions, status } = await useFetch('/api/firmware/public?full_flash=true')
const selectedId = ref<string | null>(null)

// Auto-select the newest version
watch(versions, (v) => {
  if (v?.length && !selectedId.value) {
    selectedId.value = v[0].id as string
  }
}, { immediate: true })

const selectedVersion = computed(() =>
  versions.value?.find((v: Record<string, unknown>) => v.id === selectedId.value) ?? null
)

const manifestUrl = computed(() =>
  selectedId.value ? `/api/firmware/manifest?id=${selectedId.value}` : ''
)

// Web Serial detection
const hasWebSerial = ref(false)
const espToolsLoaded = ref(false)

onMounted(async () => {
  hasWebSerial.value = 'serial' in navigator
  if (hasWebSerial.value) {
    try {
      await import('esp-web-tools')
      espToolsLoaded.value = true
    } catch (e) {
      console.error('Failed to load esp-web-tools:', e)
    }
  }
})

useHead({
  title: 'VMflow — Flash Firmware',
})
</script>

<template>
  <div class="min-h-screen bg-background text-foreground">
    <!-- Header -->
    <header class="border-b bg-background/95 backdrop-blur supports-[backdrop-filter]:bg-background/60">
      <div class="mx-auto flex max-w-3xl items-center justify-between px-4 py-4">
        <div class="flex items-center gap-2">
          <span class="text-xl font-bold">VMflow</span>
        </div>
        <LanguageSwitcher />
      </div>
    </header>

    <main class="mx-auto max-w-3xl px-4 py-8 space-y-10">
      <!-- Title & Intro -->
      <section class="space-y-2">
        <h1 class="text-3xl font-bold tracking-tight">{{ t('install.title') }}</h1>
        <p class="text-lg text-muted-foreground">{{ t('install.intro') }}</p>
      </section>

      <!-- Prerequisites -->
      <section class="space-y-3">
        <h2 class="text-xl font-semibold">{{ t('install.prerequisites') }}</h2>
        <ul class="space-y-2">
          <li class="flex items-start gap-2 text-sm">
            <span class="mt-0.5 text-green-500">&#10003;</span>
            {{ t('install.prereqBrowser') }}
          </li>
          <li class="flex items-start gap-2 text-sm">
            <span class="mt-0.5 text-green-500">&#10003;</span>
            {{ t('install.prereqInternet') }}
          </li>
          <li class="flex items-start gap-2 text-sm">
            <span class="mt-0.5 text-green-500">&#10003;</span>
            {{ t('install.prereqUsb') }}
          </li>
          <li class="flex items-start gap-2 text-sm">
            <span class="mt-0.5 text-green-500">&#10003;</span>
            {{ t('install.prereqBoard') }}
          </li>
        </ul>
      </section>

      <!-- Before Flashing -->
      <section class="space-y-4">
        <h2 class="text-xl font-semibold">{{ t('install.beforeFlash') }}</h2>

        <div class="space-y-3 rounded-lg border p-4">
          <div class="flex gap-3">
            <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">1</span>
            <p class="text-sm">{{ t('install.step1Connect') }}</p>
          </div>
          <div class="flex gap-3">
            <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">2</span>
            <p class="text-sm">{{ t('install.step2Boot') }}</p>
          </div>
          <div class="flex gap-3">
            <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">3</span>
            <div class="flex-1 space-y-2">
              <p class="text-sm">{{ t('install.step3Select') }}</p>

              <!-- Version dropdown -->
              <div v-if="status === 'pending'" class="text-sm text-muted-foreground">{{ t('common.loading') }}</div>
              <div v-else-if="!versions?.length" class="text-sm text-muted-foreground">{{ t('install.noVersions') }}</div>
              <select
                v-else
                v-model="selectedId"
                class="w-full rounded-md border bg-background px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-ring"
              >
                <option v-for="(v, i) in versions" :key="v.id" :value="v.id">
                  {{ v.version_label }}
                  <template v-if="i === 0"> ({{ t('install.latestVersion') }})</template>
                  <template v-if="v.has_full_flash"> — {{ t('install.fullFlash') }}</template>
                  <template v-else> — {{ t('install.appOnly') }}</template>
                </option>
              </select>
            </div>
          </div>
        </div>
      </section>

      <!-- Flash Button -->
      <section class="space-y-4">
        <div class="flex flex-col items-center gap-4 rounded-lg border-2 border-dashed p-8">
          <ClientOnly>
            <template v-if="hasWebSerial && espToolsLoaded && manifestUrl">
              <esp-web-install-button :manifest="manifestUrl">
                <button
                  slot="activate"
                  class="rounded-lg bg-primary px-6 py-3 text-lg font-semibold text-primary-foreground hover:bg-primary/90 transition-colors"
                >
                  {{ t('install.flashButton') }}
                </button>
                <span slot="unsupported" class="text-sm text-muted-foreground">
                  {{ t('install.unsupported') }}
                </span>
              </esp-web-install-button>
            </template>
            <template v-else-if="!hasWebSerial">
              <div class="rounded-lg border border-yellow-200 bg-yellow-50 p-4 text-sm text-yellow-800 dark:border-yellow-800 dark:bg-yellow-950 dark:text-yellow-200">
                {{ t('install.unsupported') }}
              </div>
            </template>
            <template v-else>
              <div class="text-sm text-muted-foreground">{{ t('install.loadingFlashTool') }}</div>
            </template>
            <template #fallback>
              <div class="text-sm text-muted-foreground">{{ t('common.loading') }}</div>
            </template>
          </ClientOnly>
        </div>
      </section>

      <!-- Release Notes -->
      <section v-if="selectedVersion?.notes" class="space-y-3">
        <h2 class="text-xl font-semibold">{{ t('install.releaseNotes') }}</h2>
        <div class="rounded-lg border p-4">
          <pre class="whitespace-pre-wrap text-sm text-muted-foreground">{{ selectedVersion.notes }}</pre>
        </div>
      </section>

      <!-- After Flashing -->
      <section class="space-y-4">
        <h2 class="text-xl font-semibold">{{ t('install.afterFlash') }}</h2>

        <div class="space-y-6">
          <!-- Step 1: Connect to hotspot -->
          <div class="space-y-2">
            <div class="flex gap-3">
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">1</span>
              <div>
                <p class="font-medium text-sm">{{ t('install.afterStep1Title') }}</p>
                <p class="text-sm text-muted-foreground">
                  {{ t('install.afterStep1') }}
                  <code class="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">{{ t('install.afterStep1Ssid') }}</code>
                  {{ t('install.afterStep1Detail') }}
                </p>
              </div>
            </div>
          </div>

          <!-- Step 2: Captive portal -->
          <div class="space-y-2">
            <div class="flex gap-3">
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">2</span>
              <div>
                <p class="font-medium text-sm">{{ t('install.afterStep2Title') }}</p>
                <p class="text-sm text-muted-foreground">{{ t('install.afterStep2') }}</p>
              </div>
            </div>
            <img
              src="/images/install/captive-portal-wifi.png"
              :alt="t('install.afterStep3Title')"
              class="ml-9 rounded-lg border shadow-sm max-w-md"
            />
          </div>

          <!-- Step 3: WiFi config -->
          <div class="space-y-2">
            <div class="flex gap-3">
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">3</span>
              <div>
                <p class="font-medium text-sm">{{ t('install.afterStep3Title') }}</p>
                <p class="text-sm text-muted-foreground">{{ t('install.afterStep3') }}</p>
              </div>
            </div>
          </div>

          <!-- Step 4: Provisioning code -->
          <div class="space-y-2">
            <div class="flex gap-3">
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">4</span>
              <div>
                <p class="font-medium text-sm">{{ t('install.afterStep4Title') }}</p>
                <p class="text-sm text-muted-foreground">{{ t('install.afterStep4') }}</p>
              </div>
            </div>
            <!-- How to generate a provisioning code -->
            <div class="ml-9 rounded-lg border bg-muted/50 p-4 space-y-3">
              <p class="text-sm font-medium">{{ t('install.provisioningHint') }}</p>
              <p class="text-sm text-muted-foreground">{{ t('install.provisioningHintDetail') }}</p>
              <div class="grid gap-2 sm:grid-cols-2">
                <img
                  src="/images/install/dashboard-register-device.png"
                  alt="Register device button"
                  class="rounded-lg border shadow-sm"
                />
                <img
                  src="/images/install/dashboard-provisioning-code.png"
                  alt="Provisioning code dialog"
                  class="rounded-lg border shadow-sm"
                />
              </div>
            </div>
            <img
              src="/images/install/captive-portal-code.png"
              :alt="t('install.afterStep4Title')"
              class="ml-9 rounded-lg border shadow-sm max-w-md"
            />
          </div>

          <!-- Step 5: Server URL -->
          <div class="flex gap-3">
            <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground text-xs font-bold">5</span>
            <div>
              <p class="font-medium text-sm">{{ t('install.afterStep5Title') }}</p>
              <p class="text-sm text-muted-foreground">{{ t('install.afterStep5') }}</p>
            </div>
          </div>

          <!-- Step 6: Done -->
          <div class="space-y-2">
            <div class="flex gap-3">
              <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-green-500 text-white text-xs font-bold">6</span>
              <div>
                <p class="font-medium text-sm">{{ t('install.afterStep6Title') }}</p>
                <p class="text-sm text-muted-foreground">{{ t('install.afterStep6') }}</p>
              </div>
            </div>
            <img
              src="/images/install/captive-portal-success.png"
              :alt="t('install.afterStep6Title')"
              class="ml-9 rounded-lg border shadow-sm max-w-md"
            />
          </div>
        </div>
      </section>
    </main>

    <!-- Footer -->
    <footer class="border-t py-8 mt-12">
      <div class="mx-auto max-w-3xl px-4 flex flex-wrap items-center justify-center gap-4 text-sm text-muted-foreground">
        <span>{{ t('install.footerText') }}</span>
        <a
          href="https://github.com/lucienkerl/mdb-esp32-cashless"
          target="_blank"
          rel="noopener"
          class="text-primary hover:underline"
        >
          {{ t('install.footerGithub') }}
        </a>
        <NuxtLink to="/" class="text-primary hover:underline">
          {{ t('install.footerDashboard') }}
        </NuxtLink>
      </div>
    </footer>
  </div>
</template>
