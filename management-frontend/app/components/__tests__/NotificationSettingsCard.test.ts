import { describe, it, expect, vi, beforeEach } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { ref, computed, watch, onMounted } from 'vue'
import de from '@/../i18n/locales/de.json'

// Real German strings, so the assertions read like the screen.
function translate(key: string, params?: Record<string, unknown>): string {
  let node: any = de
  for (const part of key.split('.')) node = node?.[part]
  if (typeof node !== 'string') return key
  return node.replace(/\{(\w+)\}/g, (_: string, k: string) => String(params?.[k] ?? `{${k}}`))
}

vi.stubGlobal('useI18n', () => ({ t: translate }))
vi.stubGlobal('ref', ref)
vi.stubGlobal('computed', computed)
vi.stubGlobal('watch', watch)
vi.stubGlobal('onMounted', onMounted)
vi.stubGlobal('useSupabaseUser', () => ref({ id: 'user-1' }))

let settingsRows: any[] = []
let channelInfo: any = { channels: [] }
const upserts: any[] = []
vi.stubGlobal('useSupabaseClient', () => ({
  from: () => ({
    select: () => Promise.resolve({ data: settingsRows, error: null }),
    upsert: (row: any, opts: any) => { upserts.push({ row, opts }); return Promise.resolve({ error: null }) },
  }),
  functions: { invoke: () => Promise.resolve({ data: channelInfo, error: null }) },
}))

const { useNotificationSettings } = await import('@/composables/useNotificationSettings')
vi.stubGlobal('useNotificationSettings', useNotificationSettings)
const Card = (await import('../account/NotificationSettingsCard.vue')).default

const ClientOnly = { template: '<div><slot /></div>' }

function rowOf(wrapper: ReturnType<typeof mount>, label: string) {
  return wrapper.findAll('tbody tr').find(tr => tr.text().includes(label))!
}

beforeEach(() => {
  settingsRows = []
  upserts.length = 0
  channelInfo = {
    channels: [
      { key: 'push', available: true },
      { key: 'email', available: true, configured: true, address: 'lucien@example.com' },
    ],
  }
})

describe('NotificationSettingsCard', () => {
  it('shows every event with a push and an email switch; email is opt-in', async () => {
    const w = mount(Card, { global: { stubs: { ClientOnly } } })
    await flushPromises()
    expect(w.text()).toContain('Automat offline')
    expect(w.text()).toContain('E-Mails gehen an')
    expect(w.text()).toContain('lucien@example.com')
    const row = rowOf(w, 'Automat offline')
    const switches = row.findAll('button[role="switch"]')
    expect(switches).toHaveLength(2)
    expect(switches[0]!.attributes('aria-checked')).toBe('true')  // push: default on
    expect(switches[1]!.attributes('aria-checked')).toBe('false') // email: default off
  })

  it('turning email on for "machine offline" upserts exactly that cell', async () => {
    const w = mount(Card, { global: { stubs: { ClientOnly } } })
    await flushPromises()
    await rowOf(w, 'Automat offline').findAll('button[role="switch"]')[1]!.trigger('click')
    await flushPromises()
    expect(upserts).toHaveLength(1)
    expect(upserts[0].row).toMatchObject({
      user_id: 'user-1', notification_type: 'machine_offline', channel: 'email', enabled: true,
    })
    expect(upserts[0].opts.onConflict).toBe('user_id,notification_type,channel')
    expect(rowOf(w, 'Automat offline').findAll('button[role="switch"]')[1]!.attributes('aria-checked')).toBe('true')
  })

  it('reflects stored rows (sales: push off)', async () => {
    settingsRows = [{ notification_type: 'sale', channel: 'push', enabled: false }]
    const w = mount(Card, { global: { stubs: { ClientOnly } } })
    await flushPromises()
    const s = rowOf(w, 'Verkaufsbenachrichtigungen').findAll('button[role="switch"]')
    expect(s[0]!.attributes('aria-checked')).toBe('false')
  })

  it('without SMTP the email column is disabled and explained', async () => {
    channelInfo = { channels: [{ key: 'push', available: true }, { key: 'email', available: false, configured: false, address: 'x@y' }] }
    const w = mount(Card, { global: { stubs: { ClientOnly } } })
    await flushPromises()
    expect(w.text()).toContain('E-Mail ist auf diesem Server noch nicht eingerichtet')
    const s = rowOf(w, 'Automat offline').findAll('button[role="switch"]')
    expect(s[1]!.attributes('disabled')).toBeDefined()
  })
})
