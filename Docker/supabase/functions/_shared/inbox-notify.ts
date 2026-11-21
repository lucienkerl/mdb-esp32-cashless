// Shared helper used by submit-machine-feedback + submit-product-wish to fire
// an "inbox" push notification to all operators of the affected company AND
// stamp the badge with the new open-ticket count for iOS.
//
// Per-user channel choice (notification_settings, type='inbox') is honored by
// notifyUsers — we don't need to filter here.

import { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { notifyUsers } from './notify.ts'

export type InboxKind = 'problem' | 'feedback' | 'wish'

interface NotifyParams {
  adminClient: SupabaseClient
  companyId: string
  machineId: string
  kind: InboxKind
  /** First few words of the customer's message — used as push body. */
  preview: string
}

/**
 * Count all currently-open inbox tickets across BOTH source tables for a
 * company. Used as the iOS app icon badge value. Failures fall back to
 * `undefined` (badge stays unchanged) so a transient query error never
 * blocks the push from going out.
 */
export async function getOpenInboxCount(
  adminClient: SupabaseClient,
  companyId: string,
): Promise<number | undefined> {
  try {
    const [fbRes, wishRes] = await Promise.all([
      adminClient
        .from('machine_feedback')
        .select('id', { count: 'exact', head: true })
        .eq('company_id', companyId)
        .eq('status', 'new'),
      adminClient
        .from('product_wishes')
        .select('id', { count: 'exact', head: true })
        .eq('company_id', companyId)
        .eq('status', 'new'),
    ])
    const fbCount = fbRes.count ?? 0
    const wishCount = wishRes.count ?? 0
    return fbCount + wishCount
  } catch (err) {
    console.warn('[inbox-notify] open-count query failed:', err)
    return undefined
  }
}

/**
 * Look up a machine's display name. Returns null on failure — the push will
 * still go out with a generic body.
 */
async function getMachineName(
  adminClient: SupabaseClient,
  machineId: string,
): Promise<string | null> {
  try {
    const { data } = await adminClient
      .from('vendingMachine')
      .select('name')
      .eq('id', machineId)
      .single()
    return (data as { name: string | null } | null)?.name ?? null
  } catch {
    return null
  }
}

/**
 * Build a localized title + body for the push. We don't have the user's
 * locale at the edge — falling back to German since this product is German-
 * market first. The web SW + iOS app translate the data payload separately
 * for in-app display, so the localization mismatch only affects the push
 * banner itself.
 */
function formatPush(kind: InboxKind, machineName: string | null): { title: string; body: string } {
  const machine = machineName ?? 'einem Automaten'
  switch (kind) {
    case 'problem':
      return {
        title: 'Neue Problemmeldung',
        body: `Ein Kunde hat ein Problem an ${machine} gemeldet.`,
      }
    case 'feedback':
      return {
        title: 'Neues Feedback',
        body: `Ein Kunde hat Feedback zu ${machine} hinterlassen.`,
      }
    case 'wish':
      return {
        title: 'Neuer Produktwunsch',
        body: `Ein Kunde wünscht sich ein Produkt an ${machine}.`,
      }
  }
}

export async function notifyInbox(params: NotifyParams): Promise<void> {
  const { adminClient, companyId, machineId, kind, preview } = params

  // Fire-and-forget the auxiliary lookups in parallel.
  const [machineName, badge] = await Promise.all([
    getMachineName(adminClient, machineId),
    getOpenInboxCount(adminClient, companyId),
  ])

  const { title, body } = formatPush(kind, machineName)

  // Append a short preview when we have one — keeps the banner informative
  // without leaking the entire customer message.
  const trimmedPreview = preview.trim().slice(0, 120)
  const finalBody = trimmedPreview.length > 0
    ? `${body} „${trimmedPreview}${preview.length > 120 ? '…' : ''}"`
    : body

  try {
    await notifyUsers(adminClient, companyId, 'inbox', () => ({
      title,
      body: finalBody,
      badge,
      link: '/inbox',
      data: {
        type: 'inbox',
        inbox_type: kind,
        machine_id: machineId,
      },
    }))
  } catch (err) {
    // Push failures must NEVER fail the user-facing submit. Log + continue.
    console.warn('[inbox-notify] notifyUsers failed:', err)
  }
}
