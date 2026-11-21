import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { notifyUsers } from '../_shared/notify.ts'

/**
 * check-low-stock
 *
 * Reads unsent rows from `low_stock_notifications`, groups by company,
 * sends notifications over the channels each member chose (push / email),
 * then marks rows as sent.
 *
 * Can be called periodically (e.g. via cron) or triggered after stock changes.
 * Uses service_role — no user auth required.
 */
Deno.serve(async (req) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'POST, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type, apikey, x-client-info',
      },
    })
  }

  try {
    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    )

    // Optional: verify caller is authenticated (user or webhook)
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    if (token) {
      const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
      if (userError || !user) {
        return new Response(JSON.stringify({ error: 'unauthorized' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
        })
      }
    }

    // Optional company_id filter — set by the pg_cron dispatcher so each
    // company gets its own push. Calls without a body keep the existing
    // "drain all" behavior (backward compat for older frontends).
    const contentLength = req.headers.get('content-length')
    const reqBody: Record<string, unknown> = contentLength && contentLength !== '0'
      ? await req.json().catch(() => ({}))
      : {}
    const filterCompanyId = typeof reqBody.company_id === 'string'
      ? reqBody.company_id
      : null

    // 24h guardrail: on first opt-in, the queue may contain arbitrarily
    // old undelivered rows. Only send drops from the last 24 h.
    const cutoff = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString()

    let query = adminClient
      .from('low_stock_notifications')
      .select('id, company_id, product_name, current_quantity, min_quantity')
      .is('sent_at', null)
      .gte('created_at', cutoff)
      .order('created_at')
      .limit(100)

    if (filterCompanyId) query = query.eq('company_id', filterCompanyId)

    const { data: notifications, error: fetchError } = await query

    if (fetchError) throw fetchError

    if (!notifications || notifications.length === 0) {
      return new Response(JSON.stringify({ ok: true, sent: 0, notifications: 0 }), {
        status: 200,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      })
    }

    // Group by company
    const byCompany = new Map<string, typeof notifications>()
    for (const n of notifications) {
      const list = byCompany.get(n.company_id) ?? []
      list.push(n)
      byCompany.set(n.company_id, list)
    }

    let totalSent = 0

    // Send one notification per company (batch product names)
    for (const [companyId, items] of byCompany) {
      const productList = items.map(i =>
        `${i.product_name}: ${i.current_quantity}/${i.min_quantity}`
      ).join(', ')

      const title = items.length === 1
        ? `Low stock: ${items[0].product_name}`
        : `Low stock: ${items.length} products`

      const result = await notifyUsers(adminClient, companyId, 'low_stock', () => ({
        title,
        body: productList,
        link: '/warehouse',
        data: {
          type: 'low_stock',
          products: items.map(i => ({
            product_name: i.product_name,
            current_quantity: i.current_quantity,
            min_quantity: i.min_quantity,
          })),
        },
      }))

      totalSent += result.push.sent + result.email.sent
    }

    // Mark all as sent
    const ids = notifications.map(n => n.id)
    const { error: updateError } = await adminClient
      .from('low_stock_notifications')
      .update({ sent_at: new Date().toISOString() })
      .in('id', ids)

    if (updateError) {
      console.error('Failed to mark notifications as sent:', updateError)
    }

    return new Response(JSON.stringify({
      ok: true,
      notifications: notifications.length,
      sent: totalSent,
    }), {
      status: 200,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ error: err?.message ?? String(err) }), {
      status: 500,
      headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    })
  }
})
