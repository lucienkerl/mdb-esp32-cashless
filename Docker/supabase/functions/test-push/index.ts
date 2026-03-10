import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { sendPushToUsers } from '../_shared/web-push.ts'

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

    // Verify user identity
    const token = req.headers.get('Authorization')?.replace('Bearer ', '') ?? ''
    const { data: { user }, error: userError } = await adminClient.auth.getUser(token)
    if (userError || !user) {
      return new Response(JSON.stringify({ error: 'unauthorized' }), {
        status: 401,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      })
    }

    // Get user's company
    const { data: membership } = await adminClient
      .from('organization_members')
      .select('company_id')
      .eq('user_id', user.id)
      .maybeSingle()

    if (!membership) {
      return new Response(JSON.stringify({ error: 'no organization' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
      })
    }

    // Parse optional notification type from request body
    let notifType = 'test'
    try {
      const body = await req.json()
      if (body.type && typeof body.type === 'string') notifType = body.type
    } catch { /* no body or invalid JSON — use defaults */ }

    // Look up a real product image for realistic preview
    let productImageUrl: string | undefined
    let productName = 'Coca Cola'
    if (notifType === 'sale' || notifType === 'low_stock') {
      const { data: product } = await adminClient
        .from('products')
        .select('name, image_path')
        .eq('company_id', membership.company_id)
        .not('image_path', 'is', null)
        .limit(1)
        .maybeSingle()

      if (product?.name) productName = product.name
      if (product?.image_path) {
        const supabaseUrl = Deno.env.get('SUPABASE_PUBLIC_URL') ?? Deno.env.get('SUPABASE_URL')
        productImageUrl = `${supabaseUrl}/storage/v1/object/public/product-images/${product.image_path}`
      }
    }

    // Build type-specific test payloads
    type PushPayload = { title: string; body: string; icon?: string; image?: string; data: Record<string, unknown> }
    let payload: PushPayload

    if (notifType === 'sale') {
      payload = {
        title: 'New Sale',
        body: `${productName} — €2.50 (card) · Test Machine`,
        image: productImageUrl,
        data: { type: 'sale', embedded_id: 'test' },
      }
    } else if (notifType === 'low_stock') {
      payload = {
        title: 'Low Stock Alert',
        body: `${productName} in Test Machine: 2/10 remaining`,
        image: productImageUrl,
        data: { type: 'low_stock', machine_id: 'test' },
      }
    } else {
      payload = {
        title: '🔔 Test Notification',
        body: 'Push notifications are working! This is a test from VMflow.',
        data: { type: 'test' },
      }
    }

    // Send via the full push flow (use 'sale' filter for generic test so it always sends)
    const pushType = notifType === 'test' ? 'sale' : notifType
    const result = await sendPushToUsers(adminClient, membership.company_id, pushType, payload)

    return new Response(JSON.stringify({ ok: true, ...result }), {
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
