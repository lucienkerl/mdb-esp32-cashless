import { describe, it, expect, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { computed } from 'vue'

// Nuxt auto-imports used bare in the SFCs.
vi.stubGlobal('computed', computed)
vi.stubGlobal('useI18n', () => ({
  t: (key: string, params?: Record<string, unknown>) =>
    key === 'tempSensors.ntcDefault' ? 'PCB' : params ? `${key}:${JSON.stringify(params)}` : key,
}))

import MachineTemperatureBadges from '../machine/MachineTemperatureBadges.vue'
import TemperatureSensorsSettings from '../machine/TemperatureSensorsSettings.vue'

const PROBE = 'F2000000CA146228'
const fresh = () => new Date(Date.now() - 60_000).toISOString()

describe('MachineTemperatureBadges', () => {
  it('renders nothing when no sensor is picked', () => {
    const w = mount(MachineTemperatureBadges, {
      props: { settings: [{ id: 'ntc', name: 'PCB', show: false }], diagnostics: { temps: { ntc: 41.5 } }, online: true },
    })
    expect(w.html()).toBe('<!--v-if-->')
  })

  it('shows the picked sensors with name and reading', () => {
    const w = mount(MachineTemperatureBadges, {
      props: {
        settings: [{ id: 'ntc', name: '', show: true }, { id: PROBE, name: 'Frigo', show: true }],
        diagnostics: { updated_at: fresh(), temps: { ntc: 41.46, ow: [{ id: PROBE, b: 2, t: 4.2 }] } },
        online: true,
      },
    })
    expect(w.text()).toContain('PCB')
    expect(w.text()).toContain('41.5 °C')
    expect(w.text()).toContain('Frigo')
    expect(w.text()).toContain('4.2 °C')
    expect(w.html()).not.toContain('opacity-70')
  })

  it('dims the readings when the board is offline', () => {
    const w = mount(MachineTemperatureBadges, {
      props: { settings: [{ id: 'ntc', name: 'Carte', show: true }], diagnostics: { updated_at: fresh(), temps: { ntc: 30 } }, online: false },
    })
    expect(w.text()).toContain('Carte')
    expect(w.html()).toContain('opacity-70')
  })
})

describe('TemperatureSensorsSettings', () => {
  it('lists reported sensors and emits a name and a show change', async () => {
    const w = mount(TemperatureSensorsSettings, {
      props: { modelValue: [], readings: [{ id: 'ntc', celsius: 41 }, { id: PROBE, bus: 2, celsius: 5 }] },
    })
    expect(w.findAll('li')).toHaveLength(2)
    expect(w.text()).toContain(PROBE)

    await w.findAll('input[type="text"]')[1]!.setValue('Frigo')
    expect(w.emitted('update:modelValue')![0]![0]).toEqual([{ id: PROBE, name: 'Frigo', show: false }])

    await w.findAll('input[type="checkbox"]')[0]!.setValue(true)
    expect(w.emitted('update:modelValue')![1]![0]).toEqual([{ id: 'ntc', name: '', show: true }])
  })

  it('offers to forget a saved sensor that is no longer reported', async () => {
    const w = mount(TemperatureSensorsSettings, {
      props: { modelValue: [{ id: PROBE, name: 'Ancienne', show: true }], readings: [] },
    })
    expect(w.text()).toContain('tempSensors.notSeen')
    await w.find('button').trigger('click')
    expect(w.emitted('update:modelValue')![0]![0]).toEqual([])
  })

  it('says so when nothing is reported or saved', () => {
    const w = mount(TemperatureSensorsSettings, { props: { modelValue: [], readings: [] } })
    expect(w.text()).toContain('tempSensors.none')
  })
})
