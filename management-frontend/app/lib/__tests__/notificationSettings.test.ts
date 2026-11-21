import { describe, expect, it } from 'vitest'
import {
  NOTIFICATION_EVENT_TYPES,
  channelDefault,
  enabledCount,
  isChannelEnabled,
  withChannel,
} from '../notificationSettings'

describe('notification settings matrix', () => {
  it('push defaults on, email and any later channel off (opt-in)', () => {
    expect(channelDefault('push')).toBe(true)
    expect(channelDefault('email')).toBe(false)
    expect(channelDefault('sms')).toBe(false)
    expect(isChannelEnabled([], 'sale', 'push')).toBe(true)
    expect(isChannelEnabled([], 'sale', 'email')).toBe(false)
  })

  it('a row overrides only its own cell', () => {
    const rows = [{ notification_type: 'machine_offline', channel: 'email', enabled: true }]
    expect(isChannelEnabled(rows, 'machine_offline', 'email')).toBe(true)
    expect(isChannelEnabled(rows, 'machine_offline', 'push')).toBe(true)
    expect(isChannelEnabled(rows, 'sale', 'email')).toBe(false)
  })

  it('withChannel replaces an existing cell instead of duplicating it', () => {
    let rows = withChannel([], 'sale', 'push', false)
    rows = withChannel(rows, 'sale', 'push', true)
    rows = withChannel(rows, 'sale', 'email', true)
    expect(rows).toHaveLength(2)
    expect(isChannelEnabled(rows, 'sale', 'push')).toBe(true)
    expect(isChannelEnabled(rows, 'sale', 'email')).toBe(true)
  })

  it('enabledCount counts every listed event type', () => {
    expect(enabledCount([], 'push')).toBe(NOTIFICATION_EVENT_TYPES.length)
    expect(enabledCount([], 'email')).toBe(0)
    expect(enabledCount([{ notification_type: 'machine_offline', channel: 'email', enabled: true }], 'email')).toBe(1)
  })

  it('lists the machine connectivity events', () => {
    const keys = NOTIFICATION_EVENT_TYPES.map(t => t.key)
    expect(keys).toContain('machine_offline')
    expect(keys).toContain('machine_online')
  })
})
