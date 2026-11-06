<script setup lang="ts">
import { computed } from 'vue'
import { deviceNetwork } from '@/lib/network'
import { useConnectivity } from '@/composables/useConnectivity'
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from '@/components/ui/tooltip'
import SignalIcon from '@/components/SignalIcon.vue'

/**
 * Network + signal of a device, WiFi or cellular, next to its status chip.
 * Hover / tap shows signal in dBm, IP and when it was measured.
 */
const props = withDefaults(defineProps<{
  diagnostics?: Record<string, any> | null
  /** Device is offline: show the last known network, greyed out. */
  offline?: boolean
}>(), { diagnostics: null, offline: false })

const { t } = useI18n()
const { ago } = useConnectivity()

const net = computed(() => deviceNetwork(props.diagnostics))
const kindLabel = computed(() => (net.value ? t(`connectivity.network.${net.value.kind}`) : ''))
const name = computed(() => net.value?.name ?? kindLabel.value)

/** The small pill after the name: radio mode on cellular, a warning word for a weak signal. */
const pill = computed(() => {
  const n = net.value
  if (!n) return null
  if (n.tone === 'weak' || n.tone === 'bad') return { text: t(`connectivity.network.quality.${n.quality}`), warn: true }
  return { text: n.kind === 'cellular' ? (n.mode ?? kindLabel.value) : kindLabel.value, warn: false }
})

const signalText = computed(() => {
  const n = net.value
  if (!n || n.rssi == null || !n.quality) return null
  return t('connectivity.network.signalValue', { quality: t(`connectivity.network.quality.${n.quality}`), dbm: n.rssi })
})
</script>

<template>
  <TooltipProvider v-if="net">
    <Tooltip>
      <TooltipTrigger as-child>
        <button
          type="button"
          data-testid="network-badge"
          class="inline-flex max-w-56 shrink-0 cursor-default items-center gap-1.5 rounded-md border px-2 py-0.5 text-xs"
          :class="offline
            ? 'border-dashed text-muted-foreground'
            : pill?.warn ? 'border-amber-300 bg-amber-50 dark:border-amber-700 dark:bg-amber-950/40' : ''"
          :aria-label="`${kindLabel}: ${name}${signalText ? ` · ${signalText}` : ''}`"
        >
          <SignalIcon :kind="net.kind" :level="net.level" :tone="net.tone" :muted="offline" />
          <span class="truncate font-medium" :class="offline ? '' : 'text-foreground'">
            {{ offline ? t('connectivity.network.last', { name }) : name }}
          </span>
          <span
            v-if="!offline && pill"
            class="shrink-0 rounded px-1.5 py-px text-[10px] font-semibold"
            :class="pill.warn ? 'bg-amber-100 text-amber-800 dark:bg-amber-900/50 dark:text-amber-300' : 'bg-muted text-muted-foreground'"
          >{{ pill.text }}</span>
        </button>
      </TooltipTrigger>
      <TooltipContent>
        <div class="min-w-48 text-xs">
          <p class="mb-1 font-semibold">{{ kindLabel }}<template v-if="net.name"> · {{ net.name }}</template></p>
          <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5">
            <template v-if="signalText">
              <dt class="opacity-70">{{ t('connectivity.card.signal') }}</dt><dd class="text-right">{{ signalText }}</dd>
            </template>
            <template v-if="net.mode">
              <dt class="opacity-70">{{ t('connectivity.card.mode') }}</dt><dd class="text-right">{{ net.mode }}</dd>
            </template>
            <template v-if="net.ip">
              <dt class="opacity-70">{{ t('connectivity.network.ip') }}</dt><dd class="text-right font-mono">{{ net.ip }}</dd>
            </template>
            <template v-if="net.measuredAt">
              <dt class="opacity-70">{{ t('connectivity.network.measured') }}</dt><dd class="text-right">{{ ago(net.measuredAt) }}</dd>
            </template>
          </dl>
        </div>
      </TooltipContent>
    </Tooltip>
  </TooltipProvider>
</template>
