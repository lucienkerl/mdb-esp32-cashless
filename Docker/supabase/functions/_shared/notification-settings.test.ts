/**
 * Run: deno test Docker/supabase/functions/_shared/notification-settings.test.ts
 */
import { assertEquals } from 'jsr:@std/assert'
import {
  channelDefault,
  isChannelEnabled,
  resolveRecipients,
  type NotificationSettingRow,
} from './notification-settings.ts'

const row = (user_id: string, notification_type: string, channel: string, enabled: boolean): NotificationSettingRow =>
  ({ user_id, notification_type, channel, enabled })

Deno.test('defaults: push on, email and any future channel off (opt-in)', () => {
  assertEquals(channelDefault('push'), true)
  assertEquals(channelDefault('email'), false)
  assertEquals(channelDefault('sms'), false)
  assertEquals(isChannelEnabled([], 'u1', 'sale', 'push'), true)
  assertEquals(isChannelEnabled([], 'u1', 'sale', 'email'), false)
})

Deno.test('a row overrides the default, only for its own user/type/channel', () => {
  const rows = [row('u1', 'sale', 'push', false), row('u1', 'machine_offline', 'email', true)]
  assertEquals(isChannelEnabled(rows, 'u1', 'sale', 'push'), false)
  assertEquals(isChannelEnabled(rows, 'u2', 'sale', 'push'), true)
  assertEquals(isChannelEnabled(rows, 'u1', 'machine_offline', 'email'), true)
  assertEquals(isChannelEnabled(rows, 'u1', 'machine_offline', 'push'), true)
  assertEquals(isChannelEnabled(rows, 'u1', 'sale', 'email'), false)
})

Deno.test('the example: sales push only, machine offline push + email', () => {
  const rows = [row('lucien', 'machine_offline', 'email', true)]
  const members = ['lucien']
  assertEquals([...resolveRecipients(members, rows, 'sale', 'push')], ['lucien'])
  assertEquals([...resolveRecipients(members, rows, 'sale', 'email')], [])
  assertEquals([...resolveRecipients(members, rows, 'machine_offline', 'push')], ['lucien'])
  assertEquals([...resolveRecipients(members, rows, 'machine_offline', 'email')], ['lucien'])
})

Deno.test('suppressIfAlsoEnabled works per channel', () => {
  // u1: sale on both channels → low_stock suppressed on both.
  // u2: sale push only → low_stock push suppressed, low_stock email still sent.
  // u3: sale off everywhere → low_stock on push (default), not on email (default off).
  const rows = [
    row('u1', 'sale', 'email', true),
    row('u1', 'low_stock', 'email', true),
    row('u2', 'low_stock', 'email', true),
    row('u3', 'sale', 'push', false),
  ]
  const members = ['u1', 'u2', 'u3']
  assertEquals([...resolveRecipients(members, rows, 'low_stock', 'push', 'sale')], ['u3'])
  assertEquals([...resolveRecipients(members, rows, 'low_stock', 'email', 'sale')], ['u2'])
})
