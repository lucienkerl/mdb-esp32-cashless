import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { ref } from 'vue'

vi.stubGlobal('useRuntimeConfig', () => ({ public: { supabase: { url: 'http://x' } } }))
vi.stubGlobal('useSupabaseClient', () => ({}))
vi.stubGlobal('useI18n', () => ({
  t: (key: string, params?: Record<string, unknown>) => (params ? `${key}:${JSON.stringify(params)}` : key),
  locale: ref('de'),
}))

import RefillRebuildSection from '../refill/RefillRebuildSection.vue'
import type { RebuildSlot } from '@/composables/useRefillWizard'

// The tick list at the machine: one tap on the circle marks a slot done,
// a new price is confirmed once on that tap, the row opens the amounts.
function slot(id: string, n: number, over: Partial<RebuildSlot['item']> = {}, s: Partial<RebuildSlot> = {}): RebuildSlot {
  return {
    item: {
      id, item_number: n, tray_id: `t${n}`, request_id: 'r1',
      from_product_id: 'old', to_product_id: 'new', from_capacity: 8, to_capacity: 8,
      from_price: 2, to_price: 2, from_min_age: null, to_min_age: null, skip_count: 0,
      from_name: 'Mars', to_name: 'Twix', from_image_url: null, to_image_url: null,
      from_image_path: null, to_image_path: null,
      ...over,
    } as RebuildSlot['item'],
    live_stock: 3, removed: 3, filled: 5, filled_touched: false, moved: 0, from_van: 5,
    action: null, price_set: false, age_set: false,
    ...s,
  }
}
function render(slots: RebuildSlot[]) {
  return mount(RefillRebuildSection, { props: { slots, maxFilled: () => 8, skippedSources: () => [] } })
}

describe('RefillRebuildSection', () => {
  it('marks a slot without a price change done with one tap', async () => {
    const w = render([slot('a', 12)])
    expect(w.text()).toContain('Twix')
    expect(w.text()).toContain('+5')
    await w.find('button[aria-pressed]').trigger('click')
    expect(w.emitted('action')).toEqual([['a', 'done']])
  })

  it('asks for the new price first and sets it on confirm', async () => {
    const w = render([slot('b', 14, { to_price: 2.5 })])
    await w.find('button[aria-pressed]').trigger('click')
    expect(w.emitted('action')).toBeUndefined()
    expect(w.text()).toContain('refillRebuild.priceSet')
    const yes = w.findAll('button').find(b => b.text().includes('refillRebuild.yesSetOnMachine'))!
    await yes.trigger('click')
    expect(w.emitted('price')).toEqual([['b', true]])
    expect(w.emitted('action')).toEqual([['b', 'done']])
  })

  it('opens the amounts on a row tap and can skip the slot', async () => {
    const w = render([slot('c', 23)])
    expect(w.text()).not.toContain('refillRebuild.notPossibleToday')
    await w.findAll('button')[1]!.trigger('click')
    const skip = w.findAll('button').find(b => b.text().includes('refillRebuild.notPossibleToday'))!
    await skip.trigger('click')
    expect(w.emitted('action')).toEqual([['c', 'skip']])
  })

  it('takes a done slot back with one tap', async () => {
    const w = render([slot('d', 31, {}, { action: 'done' })])
    await w.find('button[aria-pressed]').trigger('click')
    expect(w.emitted('action')).toEqual([['d', null]])
  })
})
