import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { ref, computed, watch, onMounted } from 'vue'
import de from '@/../i18n/locales/de.json'

// Real German strings, so the assertions read like the screen.
function translate(key: string, params?: Record<string, unknown>, plural?: number): string {
  let node: any = de
  for (const part of key.split('.')) node = node?.[part]
  if (typeof node !== 'string') return key
  let msg = node
  if (msg.includes(' | ')) {
    const forms = msg.split(' | ')
    msg = (plural ?? (params?.count as number) ?? 1) === 1 ? forms[0]! : forms[forms.length - 1]!
  }
  return msg.replace(/\{(\w+)\}/g, (_, k) => String(params?.[k] ?? `{${k}}`))
}

vi.stubGlobal('useI18n', () => ({ t: translate, locale: ref('de-DE') }))
vi.stubGlobal('computed', computed)
vi.stubGlobal('watch', watch)
vi.stubGlobal('onMounted', onMounted)

const logRows = ref<any[]>([])
vi.stubGlobal('useSupabaseClient', () => ({
  from: () => {
    const chain: any = {
      select: () => chain,
      eq: () => chain,
      gte: () => chain,
      order: () => Promise.resolve({ data: logRows.value, error: null }),
    }
    return chain
  },
}))

const { useConnectivity } = await import('@/composables/useConnectivity')
vi.stubGlobal('useConnectivity', useConnectivity)

const DeviceStatusChip = (await import('../DeviceStatusChip.vue')).default
const ConnectivityNotice = (await import('../machine/ConnectivityNotice.vue')).default
const ConnectivityCard = (await import('../machine/ConnectivityCard.vue')).default
const { deviceConnectivity } = await import('@/lib/connectivity')

const NOW = new Date('2026-11-04T16:00:00Z')
const minAgo = (m: number) => new Date(NOW.getTime() - m * 60000).toISOString()

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(NOW)
  logRows.value = []
})
afterEach(() => vi.useRealTimers())

describe('DeviceStatusChip', () => {
  it('shows dot and word for every state', () => {
    const cases: [any, string][] = [
      [{ status: 'online', status_at: minAgo(1) }, 'Online'],
      [{ status: 'online', status_at: minAgo(47) }, 'Keine Rückmeldung'],
      [{ status: 'offline', status_at: minAgo(120) }, 'Offline'],
      [{ status: 'ota_updating', status_at: minAgo(2) }, 'Update läuft'],
      [{ status: null }, 'Nie verbunden'],
      [null, 'Kein Gerät'],
    ]
    for (const [embedded, label] of cases) {
      const w = mount(DeviceStatusChip, { props: { connectivity: deviceConnectivity(embedded, NOW) } })
      expect(w.text()).toBe(label)
    }
  })
})

describe('ConnectivityNotice', () => {
  it('renders nothing for a healthy device', () => {
    const w = mount(ConnectivityNotice, {
      props: { connectivity: deviceConnectivity({ status: 'online', status_at: minAgo(1), mdb_diagnostics: { state: 'IDLE' } }, NOW) },
    })
    expect(w.text()).toBe('')
  })

  it('explains an offline device with the time it dropped', () => {
    const w = mount(ConnectivityNotice, {
      props: { connectivity: deviceConnectivity({ status: 'offline', status_at: minAgo(120) }, NOW) },
    })
    expect(w.text()).toContain('Offline seit 14:00 · vor 2 Std.')
    expect(w.text()).toContain('Verbindungsabbruch um 14:00')
    expect(w.text()).toContain('Prüfen:')
  })

  it('explains a silent device', () => {
    const w = mount(ConnectivityNotice, {
      props: { connectivity: deviceConnectivity({ status: 'online', status_at: minAgo(47) }, NOW) },
    })
    expect(w.text()).toContain('Letzter Kontakt vor 47 Min.')
    expect(w.text()).toContain('seit über 12 Minuten keine Heartbeats')
  })

  it('flags a machine that does not poll the reader', () => {
    const w = mount(ConnectivityNotice, {
      props: { connectivity: deviceConnectivity({ status: 'online', status_at: minAgo(1), mdb_diagnostics: { state: 'INACTIVE' } }, NOW) },
    })
    expect(w.text()).toContain('Automat antwortet nicht')
    expect(w.text()).toContain('Bargeldlos zahlen ist nicht möglich')
  })
})

describe('ConnectivityCard', () => {
  it('shows device, network, machine and the 24 h history', async () => {
    logRows.value = [
      { status: 'offline', prev_status: 'online', created_at: minAgo(12 * 60) },
      { status: 'online', prev_status: 'offline', created_at: minAgo(11 * 60 + 15) },
    ]
    const w = mount(ConnectivityCard, {
      props: {
        embedded: {
          id: 'e1',
          status: 'online',
          status_at: minAgo(1),
          online_since: minAgo(11 * 60 + 15),
          firmware_version: '2.13',
          mdb_diagnostics: { state: 'IDLE', cellular: { uplink: 'cellular', op: 'Telekom', rssi: -78, mode: 'Cat-M' } },
        },
      },
    })
    await flushPromises()
    const text = w.text()
    expect(text).toContain('Verbindung')
    expect(text).toContain('Online seit11 Std. 15 Min.')
    expect(text).toContain('Telekom')
    expect(text).toContain('-78 dBm')
    expect(text).toContain('Kasse bereit')
    expect(text).toContain('96 % online')
    expect(text).toContain('offline 04:00–04:45 (45 Min.)')
  })

  it('shows the WiFi network with signal quality, IP and measurement time', async () => {
    const w = mount(ConnectivityCard, {
      props: {
        embedded: {
          id: 'e3',
          status: 'online',
          status_at: minAgo(1),
          online_since: minAgo(60),
          mdb_diagnostics: {
            state: 'IDLE',
            network: { uplink: 'wifi', ssid: 'Büro-WLAN', rssi: -81, ip: '192.168.1.47', measured_at: minAgo(3) },
          },
        },
      },
    })
    await flushPromises()
    const text = w.text()
    expect(text).toContain('WLAN')
    expect(text).toContain('Netz (SSID)Büro-WLAN')
    expect(text).toContain('Schwach · -81 dBm')
    expect(text).toContain('192.168.1.47')
    expect(text).toContain('Schwacher Empfang')
    expect(text).not.toContain('WLAN oder unbekannt')
  })

  it('says what was before an outage and that the machine is unknown while offline', async () => {
    const w = mount(ConnectivityCard, {
      props: {
        embedded: { id: 'e2', status: 'offline', status_at: minAgo(120), online_since: minAgo(120 + 3 * 1440), mdb_diagnostics: null },
      },
    })
    await flushPromises()
    const text = w.text()
    expect(text).toContain('Offline seit14:00 (vor 2 Std.)')
    expect(text).toContain('Vorher online3 T 0 Std.')
    expect(text).toContain('WLAN oder unbekannt')
    expect(text).toContain('Unbekannt')
    expect(text).toContain('0 % online')
  })

  it('shows state, from–to and duration when hovering a segment of the bar', async () => {
    logRows.value = [
      { status: 'offline', prev_status: 'online', created_at: minAgo(12 * 60) },
      { status: 'online', prev_status: 'offline', created_at: minAgo(11 * 60 + 15) },
    ]
    const w = mount(ConnectivityCard, {
      props: { embedded: { id: 'e3', status: 'online', status_at: minAgo(1), online_since: minAgo(11 * 60 + 15) } },
      attachTo: document.body,
    })
    await flushPromises()
    const bar = w.get('[data-testid="history-bar"]')
    // jsdom has no layout: give the bar and its three segments (online · offline · online) a fixed geometry.
    const rect = (left: number, width: number) => ({ left, right: left + width, width, top: 0, bottom: 14, height: 14, x: left, y: 0, toJSON() {} }) as DOMRect
    bar.element.getBoundingClientRect = () => rect(0, 480)
    const [a, b, c] = Array.from(bar.element.children) as HTMLElement[]
    a!.getBoundingClientRect = () => rect(0, 240)
    b!.getBoundingClientRect = () => rect(241, 15)
    c!.getBoundingClientRect = () => rect(257, 223)

    // A few pixels next to the short outage still picks the outage.
    await bar.trigger('pointermove', { clientX: 262, pointerType: 'mouse' })
    const tip = w.get('[data-testid="history-tooltip"]').text()
    expect(tip).toContain('offline')
    expect(tip).toContain('45 Min.')
    expect(tip).toContain('04:00 – 04:45')

    await bar.trigger('pointermove', { clientX: 400, pointerType: 'mouse' })
    expect(w.get('[data-testid="history-tooltip"]').text()).toContain('04:45 – jetzt')

    await bar.trigger('pointerleave', { pointerType: 'mouse' })
    expect(w.find('[data-testid="history-tooltip"]').exists()).toBe(false)
    w.unmount()
  })
})
