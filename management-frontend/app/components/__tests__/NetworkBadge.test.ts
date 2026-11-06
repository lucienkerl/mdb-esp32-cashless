import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref, computed } from 'vue'
import de from '@/../i18n/locales/de.json'

function translate(key: string, params?: Record<string, unknown>): string {
  let node: any = de
  for (const part of key.split('.')) node = node?.[part]
  if (typeof node !== 'string') return key
  return node.replace(/\{(\w+)\}/g, (_, k) => String(params?.[k] ?? `{${k}}`))
}

vi.stubGlobal('useI18n', () => ({ t: translate, locale: ref('de-DE') }))
vi.stubGlobal('computed', computed)
const { useConnectivity } = await import('@/composables/useConnectivity')
vi.stubGlobal('useConnectivity', useConnectivity)

const NetworkBadge = (await import('../NetworkBadge.vue')).default

const badge = (w: ReturnType<typeof mount>) => w.find('[data-testid="network-badge"]')

describe('NetworkBadge', () => {
  it('renders nothing without uplink data', () => {
    const w = mount(NetworkBadge, { props: { diagnostics: { state: 'IDLE' } } })
    expect(badge(w).exists()).toBe(false)
  })

  it('shows SSID and a WLAN pill for a good WiFi signal', () => {
    const w = mount(NetworkBadge, {
      props: { diagnostics: { network: { uplink: 'wifi', ssid: 'Büro-WLAN', rssi: -62 } } },
    })
    expect(badge(w).text()).toContain('Büro-WLAN')
    expect(badge(w).text()).toContain('WLAN')
    expect(badge(w).attributes('aria-label')).toBe('WLAN: Büro-WLAN · Gut · -62 dBm')
  })

  it('names the problem instead of the kind when the signal is weak', () => {
    const w = mount(NetworkBadge, {
      props: { diagnostics: { network: { uplink: 'wifi', ssid: 'Lager-AP', rssi: -81 } } },
    })
    expect(badge(w).text()).toContain('Schwach')
    expect(badge(w).classes()).toContain('bg-amber-50')
  })

  it('shows operator and radio mode on cellular, also from the legacy block', () => {
    const w = mount(NetworkBadge, {
      props: { diagnostics: { cellular: { uplink: 'cellular', op: 'Telekom.de', rssi: -78, mode: 'LTE-M' } } },
    })
    expect(badge(w).text()).toContain('Telekom.de')
    expect(badge(w).text()).toContain('LTE-M')
  })

  it('greys out the last known network while offline', () => {
    const w = mount(NetworkBadge, {
      props: { offline: true, diagnostics: { network: { uplink: 'wifi', ssid: 'Schule-Gast', rssi: -60 } } },
    })
    expect(badge(w).text()).toContain('zuletzt Schule-Gast')
    expect(badge(w).classes()).toContain('border-dashed')
  })
})
