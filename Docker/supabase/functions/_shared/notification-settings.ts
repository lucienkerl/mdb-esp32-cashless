/**
 * Who gets which notification over which channel.
 *
 * Settings live in `notification_settings` (one row per user × event type ×
 * channel). A missing row means the channel's default: push is on (that was
 * the behaviour of the old per-type switches), every other channel is off — a
 * new channel is always opt-in.
 *
 * Pure and dependency-free so the resolution rules are unit-tested
 * (notification-settings.test.ts). The same default rule is mirrored in the
 * clients (web `app/lib/notificationSettings.ts`, iOS `NotificationService`).
 */

/** Channels a notification can go out on. Add a new one here + a sender in notify.ts. */
export const NOTIFICATION_CHANNELS = ['push', 'email'] as const
export type NotificationChannel = typeof NOTIFICATION_CHANNELS[number]

export interface NotificationSettingRow {
  user_id: string
  notification_type: string
  channel: string
  enabled: boolean
}

/** Default for a cell without a row: push on, everything else opt-in. */
export function channelDefault(channel: string): boolean {
  return channel === 'push'
}

/** Whether `userId` wants `type` on `channel`, given all of that user's rows (or more). */
export function isChannelEnabled(
  rows: readonly NotificationSettingRow[],
  userId: string,
  type: string,
  channel: string,
): boolean {
  const row = rows.find(
    (r) => r.user_id === userId && r.notification_type === type && r.channel === channel,
  )
  return row ? row.enabled : channelDefault(channel)
}

/**
 * The members that get `type` on `channel`.
 *
 * `suppressIfAlsoEnabled`: skip a member who also has this OTHER type enabled
 * on the same channel — e.g. no separate low-stock push for someone who gets
 * the sale push, which already carries the stock count. Per channel, so a user
 * with sale = push only still gets the low-stock email.
 */
export function resolveRecipients(
  memberIds: Iterable<string>,
  rows: readonly NotificationSettingRow[],
  type: string,
  channel: string,
  suppressIfAlsoEnabled?: string,
): Set<string> {
  const out = new Set<string>()
  for (const id of memberIds) {
    if (!isChannelEnabled(rows, id, type, channel)) continue
    if (suppressIfAlsoEnabled && isChannelEnabled(rows, id, suppressIfAlsoEnabled, channel)) continue
    out.add(id)
  }
  return out
}
