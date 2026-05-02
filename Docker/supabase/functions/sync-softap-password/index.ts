import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { generateSoftApPassword } from '../claim-device/index.ts'

const TIMESTAMP_TOLERANCE_S = 60

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

/** HMAC-SHA256(key, message) → lowercase hex. */
async function hmacSha256Hex(key: string, message: string): Promise<string> {
  const enc = new TextEncoder()
  const cryptoKey = await crypto.subtle.importKey(
    'raw', enc.encode(key),
    { name: 'HMAC', hash: 'SHA-256' },
    false, ['sign']
  )
  const sig = await crypto.subtle.sign('HMAC', cryptoKey, enc.encode(message))
  return Array.from(new Uint8Array(sig))
    .map(b => b.toString(16).padStart(2, '0'))
    .join('')
}

/** Constant-time hex string comparison. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405)
  }

  try {
    const body = await req.json()
    const { device_id, mac_address, timestamp, signature } = body

    if (typeof device_id !== 'string' || !device_id ||
        typeof mac_address !== 'string' || !mac_address ||
        typeof timestamp !== 'number' ||
        typeof signature !== 'string' || !signature) {
      return jsonResponse({ error: 'missing or malformed required field' }, 400)
    }

    const now = Math.floor(Date.now() / 1000)
    if (Math.abs(now - timestamp) > TIMESTAMP_TOLERANCE_S) {
      return jsonResponse({ error: 'timestamp out of window' }, 401)
    }

    const adminClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    )

    const { data: row, error: rowErr } = await adminClient
      .from('embeddeds')
      .select('id, mac_address, passkey, softap_password')
      .eq('id', device_id)
      .maybeSingle()

    if (rowErr) throw rowErr
    if (!row) return jsonResponse({ error: 'device not found' }, 401)
    if (row.mac_address?.toLowerCase() !== mac_address.toLowerCase()) {
      return jsonResponse({ error: 'mac mismatch' }, 401)
    }

    const expected = await hmacSha256Hex(
      row.passkey,
      `${device_id}|${mac_address}|${timestamp}`,
    )
    if (!timingSafeEqual(expected, signature.toLowerCase())) {
      return jsonResponse({ error: 'signature mismatch' }, 401)
    }

    let softapPassword = row.softap_password as string | null
    if (!softapPassword) {
      softapPassword = generateSoftApPassword()
      const { error: updErr } = await adminClient
        .from('embeddeds')
        .update({ softap_password: softapPassword })
        .eq('id', row.id)
      if (updErr) throw updErr
    }

    return jsonResponse({ softap_password: softapPassword }, 200)
  } catch (err) {
    return jsonResponse({ error: (err as Error)?.message ?? 'internal error' }, 500)
  }
})
