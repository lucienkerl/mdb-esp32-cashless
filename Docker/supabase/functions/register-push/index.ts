import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, DELETE, OPTIONS',
}

Deno.serve(async (req) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders })
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
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    const body = await req.json()

    if (req.method === 'POST') {
      const userAgent = req.headers.get('User-Agent') ?? null

      if (body.fcm_token) {
        // Native registration (iOS/Android via FCM)
        const platform = body.platform === 'ios' ? 'ios' : 'android'

        const { error } = await adminClient
          .from('push_subscriptions')
          .upsert(
            {
              user_id: user.id,
              fcm_token: body.fcm_token,
              platform,
              user_agent: userAgent,
            },
            { onConflict: 'user_id,fcm_token' },
          )

        if (error) throw error
      } else {
        // Web registration (existing VAPID flow)
        const { endpoint, keys } = body
        if (!endpoint || !keys?.p256dh || !keys?.auth) {
          return new Response(JSON.stringify({ error: 'Missing endpoint or keys' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          })
        }

        const { error } = await adminClient
          .from('push_subscriptions')
          .upsert(
            {
              user_id: user.id,
              endpoint,
              p256dh: keys.p256dh,
              auth: keys.auth,
              platform: 'web',
              user_agent: userAgent,
            },
            { onConflict: 'user_id,endpoint' },
          )

        if (error) throw error
      }

      return new Response(JSON.stringify({ ok: true }), {
        status: 201,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    if (req.method === 'DELETE') {
      // Unregister push subscription
      if (body.fcm_token) {
        // Native unregistration
        const { error } = await adminClient
          .from('push_subscriptions')
          .delete()
          .eq('user_id', user.id)
          .eq('fcm_token', body.fcm_token)

        if (error) throw error
      } else {
        // Web unregistration
        const { endpoint } = body
        if (!endpoint) {
          return new Response(JSON.stringify({ error: 'Missing endpoint or fcm_token' }), {
            status: 400,
            headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          })
        }

        const { error } = await adminClient
          .from('push_subscriptions')
          .delete()
          .eq('user_id', user.id)
          .eq('endpoint', endpoint)

        if (error) throw error
      }

      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      })
    }

    return new Response(JSON.stringify({ error: 'Method not allowed' }), {
      status: 405,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  } catch (err) {
    return new Response(JSON.stringify({ error: (err as Error)?.message ?? String(err) }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })
  }
})
