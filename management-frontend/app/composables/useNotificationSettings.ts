import {
  NOTIFICATION_CHANNELS,
  isChannelEnabled,
  withChannel,
  type NotificationChannel,
  type NotificationSettingRow,
} from '~/lib/notificationSettings'

export interface ChannelAvailability {
  key: NotificationChannel
  /** Server can deliver on this channel (push keys / SMTP configured). */
  available: boolean
  /** Email only: SMTP is configured on the server. */
  configured?: boolean
  /** Email only: where the mails go. */
  address?: string | null
}

/**
 * The signed-in user's notification matrix (event type × channel) plus which
 * channels the server can deliver. Account-wide: the same settings apply on
 * every device and app. Writes go straight to `notification_settings` (RLS:
 * own rows); a failed write rolls the switch back.
 */
export function useNotificationSettings() {
  const supabase = useSupabaseClient()
  const user = useSupabaseUser()

  const rows = ref<NotificationSettingRow[]>([])
  const channels = ref<ChannelAvailability[]>(
    NOTIFICATION_CHANNELS.map(key => ({ key, available: true })),
  )
  const loading = ref(false)
  const error = ref('')
  const saving = ref<string | null>(null)

  async function load() {
    loading.value = true
    error.value = ''
    try {
      const [settingsRes, channelsRes] = await Promise.all([
        (supabase as any)
          .from('notification_settings')
          .select('notification_type, channel, enabled'),
        supabase.functions.invoke('notification-channels', { method: 'GET' }),
      ])
      if (settingsRes.error) throw settingsRes.error
      rows.value = (settingsRes.data ?? []) as NotificationSettingRow[]

      const list = (channelsRes.data as { channels?: ChannelAvailability[] } | null)?.channels
      if (Array.isArray(list)) {
        channels.value = NOTIFICATION_CHANNELS.map(key =>
          list.find(c => c.key === key) ?? { key, available: false },
        )
      }
    } catch (err: unknown) {
      error.value = err instanceof Error ? err.message : String(err)
    } finally {
      loading.value = false
    }
  }

  function isEnabled(type: string, channel: string): boolean {
    return isChannelEnabled(rows.value, type, channel)
  }

  function channel(key: NotificationChannel): ChannelAvailability | undefined {
    return channels.value.find(c => c.key === key)
  }

  async function setEnabled(type: string, channelKey: string, enabled: boolean) {
    const userId = user.value?.id ?? (user.value as any)?.sub
    if (!userId) return
    const before = rows.value
    rows.value = withChannel(rows.value, type, channelKey, enabled)
    saving.value = `${type}:${channelKey}`
    error.value = ''
    try {
      const { error: upsertError } = await (supabase as any)
        .from('notification_settings')
        .upsert(
          {
            user_id: userId,
            notification_type: type,
            channel: channelKey,
            enabled,
            updated_at: new Date().toISOString(),
          },
          { onConflict: 'user_id,notification_type,channel' },
        )
      if (upsertError) throw upsertError
    } catch (err: unknown) {
      rows.value = before
      error.value = err instanceof Error ? err.message : String(err)
    } finally {
      saving.value = null
    }
  }

  /** Sends a test email to the signed-in user. Returns the address on success. */
  async function sendTestEmail(): Promise<{ ok: boolean; message?: string; address?: string }> {
    const { data, error: fnError } = await supabase.functions.invoke('notification-channels', {
      method: 'POST',
      body: { channel: 'email' },
    })
    if (fnError) {
      let message = fnError.message
      try {
        const body = await (fnError as any).context?.json?.()
        if (body?.error) message = body.error
      } catch { /* keep message */ }
      return { ok: false, message }
    }
    return { ok: true, address: (data as { address?: string } | null)?.address }
  }

  return { rows, channels, loading, error, saving, load, isEnabled, channel, setEnabled, sendTestEmail }
}
