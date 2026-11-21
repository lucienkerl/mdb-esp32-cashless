/**
 * Web Push utility for Supabase Edge Functions (Deno).
 *
 * Implements:
 *  - VAPID (RFC 8292) — JWT signed with ECDSA P-256
 *  - Web Push Encryption (RFC 8291) — aes128gcm content encoding
 *
 * Uses only Deno's built-in Web Crypto API — zero npm dependencies.
 */

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { normalizeLocale, type Locale } from './notification-i18n.ts'
import { loadRecipientIds } from './notification-recipients.ts'

// ─── Types ──────────────────────────────────────────────────────────────────

interface PushSubscription {
  id: string
  user_id: string
  endpoint: string | null
  p256dh: string | null
  auth: string | null
  platform: 'web' | 'android' | 'ios'
  fcm_token: string | null
  apns_topic: string | null
}

interface VapidConfig {
  publicKey: string   // base64url-encoded 65-byte uncompressed public key
  privateKey: string  // base64url-encoded 32-byte raw private key
  subject: string     // mailto: or https: URI
}

export interface PushPayload {
  title: string
  body: string
  /**
   * Optional second line of the notification. On iOS, rendered as
   * `aps.alert.subtitle` (three-line layout). On Android/FCM and web
   * push (VAPID), merged into the body with a `\n` separator because
   * those surfaces don't expose a subtitle field.
   */
  subtitle?: string
  icon?: string
  image?: string
  data?: Record<string, unknown>
  /**
   * Sets `aps.badge` on iOS pushes — controls the red number on the app icon.
   * 0 clears the badge, undefined leaves it untouched. Ignored on web/Android
   * (browsers don't surface a badge count we can drive from server-side).
   */
  badge?: number
}

// ─── Base64url helpers ──────────────────────────────────────────────────────

function base64urlToUint8Array(b64url: string): Uint8Array {
  const padding = '='.repeat((4 - b64url.length % 4) % 4)
  const b64 = (b64url + padding).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(b64)
  return Uint8Array.from(raw, c => c.charCodeAt(0))
}

function uint8ArrayToBase64url(bytes: Uint8Array): string {
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

// ─── VAPID JWT (RFC 8292) ───────────────────────────────────────────────────

async function createVapidJwt(
  audience: string,
  subject: string,
  privateKeyRaw: Uint8Array,
  publicKeyRaw: Uint8Array, // 65-byte uncompressed P-256 public key
): Promise<string> {
  const header = { typ: 'JWT', alg: 'ES256' }
  const now = Math.floor(Date.now() / 1000)
  const payload = { aud: audience, exp: now + 12 * 3600, sub: subject }

  const headerB64 = uint8ArrayToBase64url(new TextEncoder().encode(JSON.stringify(header)))
  const payloadB64 = uint8ArrayToBase64url(new TextEncoder().encode(JSON.stringify(payload)))
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)

  // Import private key via JWK using the public key x/y coordinates
  // publicKeyRaw is 65 bytes: 0x04 || x (32 bytes) || y (32 bytes)
  const x = uint8ArrayToBase64url(publicKeyRaw.subarray(1, 33))
  const y = uint8ArrayToBase64url(publicKeyRaw.subarray(33, 65))
  const d = uint8ArrayToBase64url(privateKeyRaw)

  const key = await crypto.subtle.importKey(
    'jwk',
    { kty: 'EC', crv: 'P-256', x, y, d },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )

  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    signingInput,
  )

  // Convert DER signature to raw r||s (each 32 bytes)
  const sigBytes = new Uint8Array(signature)
  const rawSig = derToRaw(sigBytes)

  return `${headerB64}.${payloadB64}.${uint8ArrayToBase64url(rawSig)}`
}

function derToRaw(der: Uint8Array): Uint8Array {
  // If already 64 bytes (raw format), return as-is
  if (der.length === 64) return der

  // Parse DER SEQUENCE { INTEGER r, INTEGER s }
  const raw = new Uint8Array(64)
  let offset = 0

  if (der[offset] === 0x30) {
    offset++ // SEQUENCE tag
    if (der[offset] & 0x80) offset += (der[offset] & 0x7f) + 1
    else offset++ // length
  }

  // Parse r
  if (der[offset] === 0x02) {
    offset++ // INTEGER tag
    const rLen = der[offset++]
    const rStart = offset + (rLen > 32 ? rLen - 32 : 0)
    const rDest = 32 - Math.min(rLen, 32)
    raw.set(der.subarray(rStart, offset + rLen), rDest)
    offset += rLen
  }

  // Parse s
  if (der[offset] === 0x02) {
    offset++ // INTEGER tag
    const sLen = der[offset++]
    const sStart = offset + (sLen > 32 ? sLen - 32 : 0)
    const sDest = 32 + 32 - Math.min(sLen, 32)
    raw.set(der.subarray(sStart, offset + sLen), sDest)
  }

  return raw
}

// ─── Web Push Encryption (RFC 8291 aes128gcm) ──────────────────────────────

async function encryptPayload(
  plaintext: Uint8Array,
  subscriptionPubKey: Uint8Array, // 65-byte uncompressed P-256 public key
  authSecret: Uint8Array,         // 16-byte auth secret
): Promise<{ body: Uint8Array; localPublicKey: Uint8Array }> {
  // 1. Generate ephemeral ECDH key pair
  const localKeyPair = await crypto.subtle.generateKey(
    { name: 'ECDH', namedCurve: 'P-256' },
    true,
    ['deriveBits'],
  )

  const localPublicKeyRaw = new Uint8Array(
    await crypto.subtle.exportKey('raw', localKeyPair.publicKey),
  )

  // 2. Import subscriber's public key
  const subscriberKey = await crypto.subtle.importKey(
    'raw',
    subscriptionPubKey,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  )

  // 3. ECDH shared secret
  const sharedSecretBits = await crypto.subtle.deriveBits(
    { name: 'ECDH', public: subscriberKey },
    localKeyPair.privateKey,
    256,
  )
  const sharedSecret = new Uint8Array(sharedSecretBits)

  // 4. Key derivation per RFC 8291
  // IKM = HKDF-SHA256(sharedSecret, authSecret, "WebPush: info\0" + subscriberPub + localPub, 32)
  const infoPrefix = new TextEncoder().encode('WebPush: info\0')
  const ikm_info = new Uint8Array(infoPrefix.length + 65 + 65)
  ikm_info.set(infoPrefix)
  ikm_info.set(subscriptionPubKey, infoPrefix.length)
  ikm_info.set(localPublicKeyRaw, infoPrefix.length + 65)

  const ikm = await hkdf(sharedSecret, authSecret, ikm_info, 32)

  // 5. Generate random 16-byte salt
  const salt = crypto.getRandomValues(new Uint8Array(16))

  // 6. Derive content encryption key (CEK) and nonce
  const cekInfo = new TextEncoder().encode('Content-Encoding: aes128gcm\0')
  const nonceInfo = new TextEncoder().encode('Content-Encoding: nonce\0')

  const cek = await hkdf(ikm, salt, cekInfo, 16)
  const nonce = await hkdf(ikm, salt, nonceInfo, 12)

  // 7. Pad plaintext (add delimiter byte 0x02 + optional padding)
  const padded = new Uint8Array(plaintext.length + 1)
  padded.set(plaintext)
  padded[plaintext.length] = 0x02 // delimiter

  // 8. Encrypt with AES-128-GCM
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    cek,
    { name: 'AES-GCM' },
    false,
    ['encrypt'],
  )

  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce },
      cryptoKey,
      padded,
    ),
  )

  // 9. Build binary body: salt(16) + rs(4) + idlen(1) + keyid(65) + ciphertext
  const rs = 4096
  const header = new Uint8Array(16 + 4 + 1 + 65)
  header.set(salt) // salt
  header[16] = (rs >> 24) & 0xff
  header[17] = (rs >> 16) & 0xff
  header[18] = (rs >> 8) & 0xff
  header[19] = rs & 0xff
  header[20] = 65 // idlen
  header.set(localPublicKeyRaw, 21) // keyid = local public key

  const body = new Uint8Array(header.length + ciphertext.length)
  body.set(header)
  body.set(ciphertext, header.length)

  return { body, localPublicKey: localPublicKeyRaw }
}

async function hkdf(
  ikm: Uint8Array,
  salt: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt, info },
    key,
    length * 8,
  )
  return new Uint8Array(bits)
}

// ─── APNs HTTP/2 API ───────────────────────────────────────────────────────

interface ApnsConfig {
  keyId: string       // Key ID from Apple Developer portal
  teamId: string      // Apple Developer Team ID
  privateKey: string  // .p8 file contents (PEM-encoded PKCS#8 EC key)
  topic: string       // App bundle identifier (e.g. com.vmflow.VMflow)
  production: boolean // true → api.push.apple.com, false → api.sandbox.push.apple.com
}

let _apnsToken: { token: string; expiresAt: number } | null = null

/**
 * Create a JWT for APNs provider authentication (ES256).
 * Token is cached for 50 minutes (APNs allows up to 1 hour).
 */
async function createApnsJwt(config: ApnsConfig): Promise<string> {
  if (_apnsToken && Date.now() < _apnsToken.expiresAt) {
    return _apnsToken.token
  }

  const header = { alg: 'ES256', kid: config.keyId }
  const now = Math.floor(Date.now() / 1000)
  const payload = { iss: config.teamId, iat: now }

  const headerB64 = uint8ArrayToBase64url(new TextEncoder().encode(JSON.stringify(header)))
  const payloadB64 = uint8ArrayToBase64url(new TextEncoder().encode(JSON.stringify(payload)))
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)

  // Import .p8 private key (PKCS#8 PEM → ECDSA P-256)
  const pemBody = config.privateKey
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s/g, '')
  const keyBytes = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0))

  const key = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )

  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    signingInput,
  )

  const rawSig = derToRaw(new Uint8Array(signature))
  const jwt = `${headerB64}.${payloadB64}.${uint8ArrayToBase64url(rawSig)}`

  _apnsToken = { token: jwt, expiresAt: Date.now() + 50 * 60 * 1000 }
  return jwt
}

/**
 * Send a push notification directly via APNs HTTP/2 API.
 */
async function sendApnsNotification(
  deviceToken: string,
  payload: PushPayload,
  config: ApnsConfig,
): Promise<{ ok: boolean; expired: boolean }> {
  const jwt = await createApnsJwt(config)

  const host = config.production
    ? 'api.push.apple.com'
    : 'api.sandbox.push.apple.com'

  const alertDict: Record<string, unknown> = {
    title: payload.title,
    body: payload.body,
  }
  if (payload.subtitle) {
    alertDict.subtitle = payload.subtitle
  }

  // Build aps separately so we can add the optional badge field cleanly.
  const aps: Record<string, unknown> = {
    alert: alertDict,
    sound: 'default',
    'mutable-content': 1,
  }
  if (typeof payload.badge === 'number') {
    aps.badge = payload.badge
  }
  const apnsPayload: Record<string, unknown> = { aps }

  // Merge custom data fields at top level (iOS reads them from userInfo)
  if (payload.data) {
    for (const [k, v] of Object.entries(payload.data)) {
      apnsPayload[k] = v
    }
  }

  // Image URL goes at the top level so the Notification Service Extension
  // can read it from `userInfo["image"]`, download it, and attach it as a
  // rich-media thumbnail. `mutable-content: 1` (set above) triggers the
  // extension. Without this, direct-APNs pushes drop the image silently.
  if (payload.image) {
    apnsPayload.image = payload.image
  }

  const resp = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: 'POST',
    headers: {
      'authorization': `bearer ${jwt}`,
      'apns-topic': config.topic,
      'apns-push-type': 'alert',
      'apns-priority': '10',
    },
    body: JSON.stringify(apnsPayload),
  })

  if (resp.ok) return { ok: true, expired: false }

  // Handle expired/invalid tokens
  const respBody = await resp.json().catch(() => ({} as Record<string, string>))
  const reason = (respBody as Record<string, string>).reason ?? ''
  console.warn(`[APNs] Push failed: status=${resp.status}, reason=${reason}, host=${host}, topic=${config.topic}, token=${deviceToken.slice(0, 8)}...`)

  if (resp.status === 410 || resp.status === 400 || resp.status === 403) {
    if (
      reason === 'Unregistered' ||
      reason === 'BadDeviceToken' ||
      reason === 'DeviceTokenNotForTopic' ||
      resp.status === 410
    ) {
      return { ok: false, expired: true }
    }
  }

  console.warn(`APNs push failed for token ${deviceToken.slice(0, 8)}...: ${resp.status}`)
  return { ok: false, expired: false }
}

// ─── FCM HTTP v1 API ────────────────────────────────────────────────────────

interface FcmServiceAccount {
  project_id: string
  private_key: string
  client_email: string
}

let _fcmAccessToken: { token: string; expiresAt: number } | null = null

async function getFcmAccessToken(sa: FcmServiceAccount): Promise<string> {
  // Reuse cached token if still valid (with 60s buffer)
  if (_fcmAccessToken && Date.now() < _fcmAccessToken.expiresAt - 60_000) {
    return _fcmAccessToken.token
  }

  const now = Math.floor(Date.now() / 1000)
  const header = { alg: 'RS256', typ: 'JWT' }
  const payload = {
    iss: sa.client_email,
    sub: sa.client_email,
    aud: 'https://oauth2.googleapis.com/token',
    iat: now,
    exp: now + 3600,
    scope: 'https://www.googleapis.com/auth/firebase.messaging',
  }

  const headerB64 = uint8ArrayToBase64url(new TextEncoder().encode(JSON.stringify(header)))
  const payloadB64 = uint8ArrayToBase64url(new TextEncoder().encode(JSON.stringify(payload)))
  const signingInput = new TextEncoder().encode(`${headerB64}.${payloadB64}`)

  // Import RSA private key (PEM → PKCS8)
  const pemBody = sa.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s/g, '')
  const keyBytes = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0))

  const key = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  )

  const signature = new Uint8Array(
    await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, signingInput),
  )

  const jwt = `${headerB64}.${payloadB64}.${uint8ArrayToBase64url(signature)}`

  // Exchange JWT for access token
  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${jwt}`,
  })

  if (!resp.ok) {
    throw new Error(`FCM token exchange failed: ${resp.status} ${await resp.text()}`)
  }

  const data = await resp.json()
  _fcmAccessToken = {
    token: data.access_token,
    expiresAt: Date.now() + data.expires_in * 1000,
  }

  return data.access_token
}

async function sendFcmNotification(
  fcmToken: string,
  platform: 'android' | 'ios',
  payload: PushPayload,
  sa: FcmServiceAccount,
): Promise<{ ok: boolean; expired: boolean }> {
  const accessToken = await getFcmAccessToken(sa)

  // FCM has no subtitle field — fold it into body so the content is preserved.
  const mergedBody = payload.subtitle
    ? `${payload.subtitle}\n${payload.body}`
    : payload.body

  const message: Record<string, unknown> = {
    token: fcmToken,
    notification: {
      title: payload.title,
      body: mergedBody,
      ...(payload.image ? { image: payload.image } : {}),
    },
    data: payload.data
      ? Object.fromEntries(Object.entries(payload.data).map(([k, v]) => [k, String(v)]))
      : undefined,
  }

  // Platform-specific config
  if (platform === 'android') {
    message.android = {
      notification: {
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
        ...(payload.icon ? { icon: payload.icon } : {}),
      },
    }
  } else {
    const fcmAps: Record<string, unknown> = {
      'mutable-content': 1,
      sound: 'default',
    }
    if (typeof payload.badge === 'number') {
      fcmAps.badge = payload.badge
    }
    message.apns = {
      payload: { aps: fcmAps },
      ...(payload.image ? { fcm_options: { image: payload.image } } : {}),
    }
  }

  const resp = await fetch(
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ message }),
    },
  )

  if (resp.ok) return { ok: true, expired: false }

  // Token no longer valid (unregistered / app uninstalled)
  if (resp.status === 404 || resp.status === 400) {
    const body = await resp.json().catch(() => ({}))
    const code = body?.error?.details?.[0]?.errorCode ?? body?.error?.code ?? ''
    if (code === 'UNREGISTERED' || code === 'INVALID_ARGUMENT' || resp.status === 404) {
      return { ok: false, expired: true }
    }
  }

  console.warn(`FCM push failed for token ${fcmToken.slice(0, 8)}...: ${resp.status}`)
  return { ok: false, expired: false }
}

// ─── Send Push Notification ─────────────────────────────────────────────────

async function sendPushNotification(
  subscription: { endpoint: string; p256dh: string; auth: string },
  payload: PushPayload,
  vapid: VapidConfig,
): Promise<Response> {
  // Web push has no subtitle field in the payload the service worker sees —
  // fold it into body so the content is preserved.
  const wirePayload: PushPayload = payload.subtitle
    ? { ...payload, body: `${payload.subtitle}\n${payload.body}` }
    : payload

  const payloadBytes = new TextEncoder().encode(JSON.stringify(wirePayload))
  const subscriberPubKey = base64urlToUint8Array(subscription.p256dh)
  const authSecret = base64urlToUint8Array(subscription.auth)
  const vapidPrivateKey = base64urlToUint8Array(vapid.privateKey)
  const vapidPublicKey = base64urlToUint8Array(vapid.publicKey)

  // Encrypt payload
  const { body } = await encryptPayload(payloadBytes, subscriberPubKey, authSecret)

  // Build VAPID Authorization header
  const endpointUrl = new URL(subscription.endpoint)
  const audience = `${endpointUrl.protocol}//${endpointUrl.host}`
  const jwt = await createVapidJwt(audience, vapid.subject, vapidPrivateKey, vapidPublicKey)

  return fetch(subscription.endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/octet-stream',
      'Content-Encoding': 'aes128gcm',
      'Content-Length': String(body.length),
      Authorization: `vapid t=${jwt}, k=${vapid.publicKey}`,
      TTL: '86400',
      Urgency: 'normal',
    },
    body,
  })
}

// ─── Main helper: send to all users in a company ────────────────────────────

export async function sendPushToUsers(
  adminClient: SupabaseClient,
  companyId: string,
  notificationType: string,
  payloadOrBuilder: PushPayload | ((locale: Locale) => PushPayload),
  options?: {
    /**
     * Skip users who also have this OTHER notification type enabled on the
     * push channel. Useful to avoid redundant alerts when the current push
     * duplicates info already delivered by another type (e.g. low_stock when
     * the sale push already shows the stock count).
     */
    suppressIfAlsoEnabled?: string
  },
): Promise<{ sent: number; expired: number }> {
  // Normalize to a builder. Legacy callers that pass a plain PushPayload
  // get the same payload for every locale group — functionally identical
  // to the pre-locale behavior. New callers pass the builder directly.
  const buildPayload: (locale: Locale) => PushPayload =
    typeof payloadOrBuilder === 'function'
      ? payloadOrBuilder
      : () => payloadOrBuilder

  // VAPID config for web push
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY')
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY')
  const subject = Deno.env.get('VAPID_SUBJECT')
  const hasVapid = !!(publicKey && privateKey && subject)

  // APNs config for iOS native push
  const apnsKeyId = Deno.env.get('APNS_KEY_ID')
  const apnsTeamId = Deno.env.get('APNS_TEAM_ID')
  const apnsPrivateKey = Deno.env.get('APNS_PRIVATE_KEY')
  const apnsTopic = Deno.env.get('APNS_TOPIC')
  const apnsConfig: ApnsConfig | null =
    apnsKeyId && apnsTeamId && apnsPrivateKey && apnsTopic
      ? {
          keyId: apnsKeyId,
          teamId: apnsTeamId,
          privateKey: apnsPrivateKey,
          topic: apnsTopic,
          production: Deno.env.get('APNS_PRODUCTION') !== 'false',
        }
      : null

  // FCM config for Android native push
  const fcmJson = Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')
  let fcmServiceAccount: FcmServiceAccount | null = null
  if (fcmJson) {
    try {
      fcmServiceAccount = JSON.parse(fcmJson)
    } catch {
      console.warn('FCM_SERVICE_ACCOUNT_JSON is not valid JSON — Android push disabled')
    }
  }

  // If nothing is configured, skip entirely
  if (!hasVapid && !apnsConfig && !fcmServiceAccount) {
    return { sent: 0, expired: 0 }
  }

  const vapid: VapidConfig | null = hasVapid
    ? { publicKey: publicKey!, privateKey: privateKey!, subject: subject! }
    : null

  // Members of this company who want this type on the push channel
  // (notification_settings; missing row = push on).
  const recipientIds = await loadRecipientIds(
    adminClient,
    companyId,
    notificationType,
    'push',
    options?.suppressIfAlsoEnabled,
  )
  if (recipientIds.size === 0) {
    return { sent: 0, expired: 0 }
  }

  const { data: allSubs, error: subsError } = await adminClient
    .from('push_subscriptions')
    .select('id, endpoint, p256dh, auth, user_id, platform, fcm_token, apns_topic')
    .in('user_id', [...recipientIds])

  if (subsError || !allSubs || allSubs.length === 0) {
    return { sent: 0, expired: 0 }
  }

  const subscriptions = allSubs as PushSubscription[]

  if (subscriptions.length === 0) {
    return { sent: 0, expired: 0 }
  }

  // Bulk-fetch locale for all remaining subscribers. Absence of row or
  // unknown value → 'en' (matches today's behavior byte-for-byte).
  const userIds = [...new Set(subscriptions.map((s) => s.user_id))]
  const { data: userRows } = await adminClient
    .from('users')
    .select('id, locale')
    .in('id', userIds)

  const localeByUser = new Map<string, Locale>(
    (userRows ?? []).map((r: { id: string; locale: string | null }) => [
      r.id,
      normalizeLocale(r.locale),
    ]),
  )

  // Group recipients by locale.
  const groupedByLocale = new Map<Locale, PushSubscription[]>()
  for (const sub of subscriptions) {
    const loc = localeByUser.get(sub.user_id) ?? 'en'
    const bucket = groupedByLocale.get(loc) ?? []
    bucket.push(sub)
    groupedByLocale.set(loc, bucket)
  }

  let sent = 0
  let expired = 0
  const expiredIds: string[] = []

  // Dispatch per locale group — each group sees a freshly-built payload
  // in its language.
  for (const [locale, groupSubs] of groupedByLocale) {
    const payload = buildPayload(locale)

    const webSubs = groupSubs.filter(
      (s) => s.platform === 'web' && s.endpoint && s.p256dh && s.auth,
    )
    const iosSubs = groupSubs.filter((s) => s.platform === 'ios' && s.fcm_token)
    const androidSubs = groupSubs.filter((s) => s.platform === 'android' && s.fcm_token)

    // Send web push notifications (VAPID)
    if (vapid && webSubs.length > 0) {
      await Promise.allSettled(
        webSubs.map(async (sub) => {
          try {
            const response = await sendPushNotification(
              { endpoint: sub.endpoint!, p256dh: sub.p256dh!, auth: sub.auth! },
              payload,
              vapid,
            )
            if (response.ok || response.status === 201) {
              sent++
            } else if (response.status === 404 || response.status === 410) {
              expired++
              expiredIds.push(sub.id)
            } else {
              console.warn(`Push failed for ${sub.endpoint}: ${response.status}`)
            }
          } catch (err) {
            console.warn(`Push error for ${sub.endpoint}:`, err)
          }
        }),
      )
    }

    // Send iOS push notifications (APNs direct)
    if (apnsConfig && iosSubs.length > 0) {
      await Promise.allSettled(
        iosSubs.map(async (sub) => {
          try {
            // Use per-subscription bundle ID if stored, otherwise fall back to env var
            const perSubConfig = sub.apns_topic
              ? { ...apnsConfig!, topic: sub.apns_topic }
              : apnsConfig!
            const result = await sendApnsNotification(sub.fcm_token!, payload, perSubConfig)
            if (result.ok) {
              sent++
            } else if (result.expired) {
              expired++
              expiredIds.push(sub.id)
            }
          } catch (err) {
            console.warn(`APNs push error for token ${sub.fcm_token?.slice(0, 8)}...:`, err)
          }
        }),
      )
    }

    // Send Android push notifications (FCM)
    if (fcmServiceAccount && androidSubs.length > 0) {
      await Promise.allSettled(
        androidSubs.map(async (sub) => {
          try {
            const result = await sendFcmNotification(
              sub.fcm_token!,
              'android',
              payload,
              fcmServiceAccount!,
            )
            if (result.ok) {
              sent++
            } else if (result.expired) {
              expired++
              expiredIds.push(sub.id)
            }
          } catch (err) {
            console.warn(`FCM push error for token ${sub.fcm_token?.slice(0, 8)}...:`, err)
          }
        }),
      )
    }
  }

  // Clean up expired subscriptions (runs once after all locale groups)
  if (expiredIds.length > 0) {
    try {
      await adminClient
        .from('push_subscriptions')
        .delete()
        .in('id', expiredIds)
    } catch (err) {
      console.warn('Failed to clean up expired subscriptions:', err)
    }
  }

  return { sent, expired }
}
