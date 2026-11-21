import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { resolveRecipients, type NotificationSettingRow } from './notification-settings.ts'

/**
 * Members of `companyId` that want `type` on `channel` (see
 * notification-settings.ts for the rules). One query for the members, one
 * for their settings rows of the two types involved.
 */
export async function loadRecipientIds(
  adminClient: SupabaseClient,
  companyId: string,
  type: string,
  channel: string,
  suppressIfAlsoEnabled?: string,
): Promise<Set<string>> {
  const { data: members } = await adminClient
    .from('organization_members')
    .select('user_id')
    .eq('company_id', companyId)

  const memberIds = (members ?? []).map((m: { user_id: string }) => m.user_id)
  if (memberIds.length === 0) return new Set()

  const types = suppressIfAlsoEnabled ? [type, suppressIfAlsoEnabled] : [type]
  const { data: rows, error } = await adminClient
    .from('notification_settings')
    .select('user_id, notification_type, channel, enabled')
    .eq('channel', channel)
    .in('notification_type', types)
    .in('user_id', memberIds)

  if (error) {
    // Fail closed for opt-in channels, open for push (its default is on) —
    // the same outcome a user without rows would get.
    console.warn(`[notify] settings query failed (${channel}):`, error.message)
  }

  return resolveRecipients(
    memberIds,
    (rows ?? []) as NotificationSettingRow[],
    type,
    channel,
    suppressIfAlsoEnabled,
  )
}
