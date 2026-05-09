import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'

// Use the shared Nuxt auto-import stub but override `useSupabaseClient`,
// because `nuxt-stubs.ts` deliberately throws on it (composables are
// expected to provide their own mock per test). The component calls
// `useSupabaseClient()` eagerly at script-setup top level, so we must
// give it a chainable no-op stub regardless of company id.
vi.mock('#imports', async () => ({
  ...(await import('@/test-helpers/nuxt-stubs')),
  useSupabaseClient: () => ({
    from: () => ({
      select: () => ({
        eq: () => ({
          not: () => ({ limit: () => ({ data: [], error: null }), data: [], error: null }),
          data: [],
          error: null,
        }),
      }),
    }),
  }),
}))

// `filter` mirrors the production shape (Ref-like with .value); using a real
// Vue ref means template auto-unwrap resolves `filter.machines` etc. to the
// underlying arrays, so MultiSelectPill receives a real Array prop.
vi.mock('@/composables/useAnalyticsFilters', async () => {
  const { ref } = await import('vue')
  return {
    useAnalyticsFilters: () => ({
      filter: ref({
        v: 1,
        from: '2026-04-09T00:00:00.000Z',
        to: '2026-05-09T00:00:00.000Z',
        compare: false,
        machines: [] as string[],
        channels: [] as string[],
        categories: [] as string[],
        vatRates: [] as number[],
      }),
      reset: vi.fn(),
      savePreset: vi.fn(),
      loadPreset: vi.fn(),
      listPresets: () => [],
      deletePreset: vi.fn(),
    }),
  }
})

vi.mock('@/composables/useOrganization', () => ({
  useOrganization: () => ({ organization: { value: null } }),
}))

import AnalyticsFilterBar from '../AnalyticsFilterBar.vue'

describe('AnalyticsFilterBar', () => {
  it('mounts without errors and renders the expected filter slots', () => {
    const wrapper = mount(AnalyticsFilterBar, {
      global: {
        stubs: {
          Popover: { template: '<div><slot /></div>' },
          PopoverTrigger: { template: '<div><slot /></div>' },
          PopoverContent: { template: '<div><slot /></div>' },
          Command: { template: '<div><slot /></div>' },
          CommandInput: { template: '<input />' },
          CommandList: { template: '<div><slot /></div>' },
          CommandGroup: { template: '<div><slot /></div>' },
          CommandEmpty: { template: '<div><slot /></div>' },
          Badge: { template: '<span><slot /></span>' },
          Switch: { template: '<button />' },
          Button: { template: '<button><slot /></button>' },
          DropdownMenu: { template: '<div><slot /></div>' },
          DropdownMenuTrigger: { template: '<div><slot /></div>' },
          DropdownMenuContent: { template: '<div><slot /></div>' },
          DropdownMenuItem: { template: '<div><slot /></div>' },
          DropdownMenuSeparator: { template: '<hr />' },
          MultiProductCommandItem: { template: '<div><slot /></div>' },
        },
      },
    })

    expect(wrapper.exists()).toBe(true)
    // The bar container is present
    expect(wrapper.find('[data-testid="analytics-filter-bar"]').exists()).toBe(true)
    // All seven advertised filter slots exist (filter-machines / filter-categories
    // / filter-vat are emitted by the inner MultiSelectPill component but their
    // testid prop must still propagate to the rendered button).
    expect(wrapper.find('[data-testid="filter-date"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-compare"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-machines"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-channels"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-categories"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-vat"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-reset"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="filter-presets"]').exists()).toBe(true)
  })
})
