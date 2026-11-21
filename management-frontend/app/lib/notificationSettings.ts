/**
 * Notification settings matrix: event type × channel.
 *
 * Rows live in `notification_settings` (user_id, notification_type, channel,
 * enabled). A missing row means the channel's default: push on (the old
 * per-type switches defaulted to on), every other channel off — a new channel
 * is always opt-in. Same rule as the backend
 * (`Docker/supabase/functions/_shared/notification-settings.ts`) and iOS
 * (`NotificationService.swift`); keep them together.
 */

export type NotificationChannel = 'push' | 'email'

/** Column order in the matrix. Adding a channel: add it here + a sender in the backend's notify.ts. */
export const NOTIFICATION_CHANNELS: NotificationChannel[] = ['push', 'email']

export interface NotificationEventType {
  key: string
  /** Tabler icon name hint for the UI. */
  icon: 'cash' | 'package' | 'wifi-off' | 'wifi' | 'inbox' | 'tag'
}

/** Row order in the matrix. Labels/descriptions: i18n `settings.notifTypes.<key>`. */
export const NOTIFICATION_EVENT_TYPES: NotificationEventType[] = [
  { key: 'sale', icon: 'cash' },
  { key: 'low_stock', icon: 'package' },
  { key: 'machine_offline', icon: 'wifi-off' },
  { key: 'machine_online', icon: 'wifi' },
  { key: 'inbox', icon: 'inbox' },
  { key: 'new_deals', icon: 'tag' },
]

export interface NotificationSettingRow {
  notification_type: string
  channel: string
  enabled: boolean
}

export function channelDefault(channel: string): boolean {
  return channel === 'push'
}

export function isChannelEnabled(
  rows: readonly NotificationSettingRow[],
  type: string,
  channel: string,
): boolean {
  const row = rows.find(r => r.notification_type === type && r.channel === channel)
  return row ? row.enabled : channelDefault(channel)
}

/** Returns a new row list with one cell set (replacing an existing row). */
export function withChannel(
  rows: readonly NotificationSettingRow[],
  type: string,
  channel: string,
  enabled: boolean,
): NotificationSettingRow[] {
  const rest = rows.filter(r => !(r.notification_type === type && r.channel === channel))
  return [...rest, { notification_type: type, channel, enabled }]
}

/** How many event types a channel is on for (column summary). */
export function enabledCount(rows: readonly NotificationSettingRow[], channel: string): number {
  return NOTIFICATION_EVENT_TYPES.filter(t => isChannelEnabled(rows, t.key, channel)).length
}
