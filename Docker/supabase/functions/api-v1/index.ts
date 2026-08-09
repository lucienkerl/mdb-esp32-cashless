import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'
import { validateApiKey } from '../_shared/api-key-auth.ts'

// ── Constants ───────────────────────────────────────────────────────────────

const FUNCTION_PREFIX = '/api-v1'

/** Allowlist: API path → PostgREST table/view name. Unlisted paths → 404. */
const CRUD_ROUTES: Record<string, { table: string; readOnly: boolean; extraMethods?: string[] }> = {
  machines:        { table: 'vendingMachine', readOnly: false },
  sales:           { table: 'sales',          readOnly: true },
  products:        { table: 'products',       readOnly: false },
  categories:      { table: 'product_category', readOnly: false },
  devices:         { table: 'api_embeddeds',  readOnly: true },
  trays:           { table: 'machine_trays',  readOnly: false },
  warehouses:      { table: 'warehouses',     readOnly: false },
  'stock-batches': { table: 'warehouse_stock_batches', readOnly: false },
  paxcounter:      { table: 'paxcounter',     readOnly: true },
  'activity-log':  { table: 'activity_log',   readOnly: true },
  // Purchase prices (Einkaufspreise) + suppliers. Read via CRUD; writes go
  // through the RPC actions below so net/gross + supplier find-or-create + tax
  // resolution run server-side (a raw table insert would bypass all of that).
  suppliers:         { table: 'suppliers',                readOnly: true },
  // Read + DELETE; create/update go through the RPC actions (net/gross + supplier).
  'purchase-prices': { table: 'product_purchase_prices',  readOnly: true, extraMethods: ['DELETE'] },
  // Read-only resources for API/MCP visibility. All RLS company-scoped. Writes are
  // omitted because their RLS WITH CHECK needs company_id, which an API client can't
  // discover — expose dedicated write actions later if needed.
  barcodes:                 { table: 'product_barcodes',            readOnly: true },
  'warehouse-transactions': { table: 'warehouse_transactions',      readOnly: true },
  'min-stock':              { table: 'product_min_stock',           readOnly: true },
  'warehouse-positions':    { table: 'warehouse_product_positions', readOnly: true },
  'tax-classes':            { table: 'tax_classes',                 readOnly: true },
  'tax-rates':              { table: 'tax_rates',                   readOnly: true },
  firmware:                 { table: 'firmware_versions',           readOnly: true },
  // Broad read-only exposure. All RLS company-scoped — directly, or via joins on
  // embeddeds/vendingMachine/deal_keywords; system_tax_rates is global reference
  // data. NOTE: machine_insights_history/_cache are deliberately NOT exposed —
  // their SELECT policy is USING(true), which would leak across companies.
  deals:                       { table: 'deal_cache',                    readOnly: true },
  'deal-keywords':             { table: 'deal_keywords',                 readOnly: true },
  'deal-keyword-products':     { table: 'deal_keyword_products',         readOnly: true },
  'cash-books':                { table: 'cash_books',                    readOnly: true },
  'cash-book-entries':         { table: 'cash_book_entries',             readOnly: true },
  payments:                    { table: 'payments',                      readOnly: true },
  'suppressed-sales':          { table: 'suppressed_sales',              readOnly: true },
  'stock-decrement-log':       { table: 'stock_decrement_log',           readOnly: true },
  'mdb-log':                   { table: 'mdb_log',                       readOnly: true },
  'dex-snapshots':             { table: 'dex_snapshots',                 readOnly: true },
  'device-restarts':           { table: 'device_restarts',               readOnly: true },
  'ota-updates':               { table: 'ota_updates',                   readOnly: true },
  'product-offerings':         { table: 'machine_product_offerings',     readOnly: true },
  'machine-feedback':          { table: 'machine_feedback',              readOnly: true },
  'product-wishes':            { table: 'product_wishes',                readOnly: true },
  'restock-subscriptions':     { table: 'restock_subscriptions',         readOnly: true },
  'refill-applications':       { table: 'refill_tour_tray_applications', readOnly: true },
  'warehouse-position-groups': { table: 'warehouse_position_groups',     readOnly: true },
  'system-tax-rates':          { table: 'system_tax_rates',              readOnly: true },
}

/** Action endpoints → target edge function name. */
const ACTION_ROUTES: Record<string, string> = {
  'send-credit':  'send-credit',
  'trigger-ota':  'trigger-ota',
  'send-config':  'send-device-config',
}

/** Action endpoints that proxy to a PostgREST RPC (clean body → p_-prefixed args). */
const RPC_ACTIONS: Record<string, string> = {
  'add-purchase-price':    'add_purchase_price',
  'update-purchase-price': 'update_purchase_price',
}

const JWT_TTL_SECONDS = 60

// ── Rate limiter (best-effort in-memory) ────────────────────────────────────

const rateLimitMap = new Map<string, number[]>()

function checkRateLimit(keyId: string, limit: number): { allowed: boolean; retryAfter: number } {
  const now = Date.now()
  const windowMs = 60_000
  const timestamps = (rateLimitMap.get(keyId) ?? []).filter((t) => now - t < windowMs)

  if (timestamps.length >= limit) {
    const oldestInWindow = timestamps[0]
    const retryAfter = Math.ceil((oldestInWindow + windowMs - now) / 1000)
    return { allowed: false, retryAfter }
  }

  timestamps.push(now)
  rateLimitMap.set(keyId, timestamps)
  return { allowed: true, retryAfter: 0 }
}

// ── Helpers ─────────────────────────────────────────────────────────────────

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

function errorResponse(
  error: string,
  message: string,
  status: number,
  extra?: Record<string, unknown>,
): Response {
  return jsonResponse({ error, message, ...extra }, status)
}

/**
 * Parse the request path into a resource name and optional ID.
 * Input path from edge runtime: `/api-v1/machines/some-uuid`
 * Returns: { resource: 'machines', id: 'some-uuid' | null }
 */
function parsePath(pathname: string): { resource: string; id: string | null; subpath: string | null } {
  const stripped = pathname.replace(FUNCTION_PREFIX, '').replace(/^\/+/, '')
  const segments = stripped.split('/').filter(Boolean)
  return {
    resource: segments[0] ?? '',
    id: segments[1] ?? null,
    subpath: segments.length > 2 ? segments.slice(1).join('/') : null,
  }
}

/**
 * Mint a short-lived JWT that PostgREST trusts.
 * Contains api_company_id + api_key_id so my_company_id() / i_am_admin() work.
 */
async function mintJwt(
  apiKeyId: string,
  companyId: string,
  secret: string,
): Promise<string> {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )

  const now = Math.floor(Date.now() / 1000)
  return await new jose.SignJWT({
    role: 'authenticated',
    api_company_id: companyId,
    api_key_id: apiKeyId,
    iss: 'vmflow-api-gateway',
  })
    .setSubject(apiKeyId)
    .setIssuedAt(now)
    .setExpirationTime(now + JWT_TTL_SECONDS)
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .sign(key)
}

// ── Main handler ────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const url = new URL(req.url)
  const { resource, id } = parsePath(url.pathname)

  // ── CORS preflight ──
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204 })
  }

  // ── Public documentation endpoints (no auth) ──
  if (resource === 'docs') {
    return serveSwaggerUI()
  }
  if (resource === 'openapi.yaml') {
    return serveOpenApiSpec()
  }

  // ── API key authentication ──
  const apiKey = req.headers.get('X-API-Key')
  if (!apiKey) {
    return errorResponse(
      'unauthorized',
      'Missing X-API-Key header. Obtain a key from the management dashboard at /api-keys.',
      401,
    )
  }

  const adminClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  let keyInfo: { id: string; company_id: string; rate_limit: number }
  try {
    keyInfo = await validateApiKey(apiKey, adminClient)
  } catch (err: any) {
    return errorResponse('unauthorized', err.message, err.status ?? 401)
  }

  // ── Rate limiting ──
  const rl = checkRateLimit(keyInfo.id, keyInfo.rate_limit)
  if (!rl.allowed) {
    return errorResponse(
      'rate_limit_exceeded',
      `Rate limit of ${keyInfo.rate_limit} requests per minute exceeded.`,
      429,
      { retry_after: rl.retryAfter },
    )
  }

  // ── Route: Actions ──
  if (resource === 'actions' && id) {
    const rpcName = RPC_ACTIONS[id]
    if (rpcName) {
      return proxyRpc(req, rpcName, keyInfo)
    }
    const fnName = ACTION_ROUTES[id]
    if (!fnName) {
      return errorResponse('not_found', `Unknown action: ${id}`, 404)
    }
    return proxyAction(req, fnName, keyInfo.company_id, apiKey)
  }

  // ── Route: CRUD via PostgREST ──
  const route = CRUD_ROUTES[resource]
  if (!route) {
    return errorResponse('not_found', `Unknown resource: ${resource}. Available: ${Object.keys(CRUD_ROUTES).join(', ')}`, 404)
  }

  if (route.readOnly && req.method !== 'GET' && !(route.extraMethods ?? []).includes(req.method)) {
    return errorResponse(
      'forbidden',
      `Resource '${resource}' is read-only. Only GET requests are allowed.`,
      403,
    )
  }

  return proxyCrud(req, url, route.table, id, keyInfo)
})

// ── PostgREST CRUD proxy ────────────────────────────────────────────────────

async function proxyCrud(
  req: Request,
  url: URL,
  table: string,
  resourceId: string | null,
  keyInfo: { id: string; company_id: string },
): Promise<Response> {
  const jwtSecret = Deno.env.get('JWT_SECRET')
  if (!jwtSecret) {
    return errorResponse('internal_error', 'JWT_SECRET not configured', 500)
  }

  const jwt = await mintJwt(keyInfo.id, keyInfo.company_id, jwtSecret)
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!

  // Build PostgREST URL
  // PostgREST is at http://rest:3000 inside Docker network.
  // NOTE: This hardcoded URL only works in Docker compose. For local dev
  // via `supabase functions serve`, PostgREST proxy won't connect.
  // Use Docker compose for full integration testing.
  const postgrestPath = `/${table}`

  // Convenience: /machines/<uuid> → ?id=eq.<uuid>
  const queryParams = new URLSearchParams(url.search)
  let singleResource = false
  if (resourceId) {
    queryParams.set('id', `eq.${resourceId}`)
    if (req.method === 'GET') {
      // Return singular object (PostgREST Accept header)
      singleResource = true
    }
  }

  const postgrestUrl = `http://rest:3000${postgrestPath}?${queryParams.toString()}`

  const headers: Record<string, string> = {
    Authorization: `Bearer ${jwt}`,
    apikey: anonKey,
  }

  // Forward relevant request headers
  const contentType = req.headers.get('Content-Type')
  if (contentType) headers['Content-Type'] = contentType

  const prefer = req.headers.get('Prefer')
  if (prefer) headers['Prefer'] = prefer

  // For single resource GET, request singular response
  if (singleResource) {
    headers['Accept'] = 'application/vnd.pgrst.object+json'
  }

  const body = req.method !== 'GET' && req.method !== 'HEAD'
    ? await req.text()
    : undefined

  try {
    const response = await fetch(postgrestUrl, {
      method: req.method,
      headers,
      body,
    })

    // Pass through PostgREST response with appropriate headers
    const responseHeaders = new Headers()
    responseHeaders.set('Content-Type', response.headers.get('Content-Type') ?? 'application/json')

    // Forward pagination headers
    const contentRange = response.headers.get('Content-Range')
    if (contentRange) responseHeaders.set('Content-Range', contentRange)

    return new Response(await response.text(), {
      status: response.status,
      headers: responseHeaders,
    })
  } catch (err: any) {
    return errorResponse('internal_error', `Proxy error: ${err.message}`, 502)
  }
}

// ── Action proxy ────────────────────────────────────────────────────────────

async function proxyAction(
  req: Request,
  functionName: string,
  companyId: string,
  originalApiKey: string,
): Promise<Response> {
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  const supabaseUrl = Deno.env.get('SUPABASE_URL')!

  const body = await req.text()

  // send-credit already supports X-API-Key natively — forward it directly.
  // trigger-ota and send-device-config use service-role + X-Company-Id pattern.
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (functionName === 'send-credit') {
    headers['X-API-Key'] = originalApiKey
  } else {
    headers['Authorization'] = `Bearer ${serviceRoleKey}`
    headers['X-Company-Id'] = companyId
  }

  try {
    const response = await fetch(`${supabaseUrl}/functions/v1/${functionName}`, {
      method: 'POST',
      headers,
      body,
    })

    const responseBody = await response.text()
    return new Response(responseBody, {
      status: response.status,
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (err: any) {
    return errorResponse('internal_error', `Action proxy error: ${err.message}`, 502)
  }
}

// ── RPC proxy (PostgREST /rpc/<name>) ───────────────────────────────────────

async function proxyRpc(
  req: Request,
  rpcName: string,
  keyInfo: { id: string; company_id: string },
): Promise<Response> {
  const jwtSecret = Deno.env.get('JWT_SECRET')
  if (!jwtSecret) {
    return errorResponse('internal_error', 'JWT_SECRET not configured', 500)
  }
  const jwt = await mintJwt(keyInfo.id, keyInfo.company_id, jwtSecret)
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!

  // Map the clean external body ({product_id, supplier_name, …}) onto the RPC's
  // named args (p_product_id, …). Omitted args fall back to the SQL defaults.
  let clientBody: Record<string, unknown> = {}
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    const raw = await req.text()
    if (raw) {
      try {
        clientBody = JSON.parse(raw)
      } catch {
        return errorResponse('bad_request', 'Invalid JSON body', 400)
      }
    }
  }
  const rpcBody: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(clientBody)) rpcBody[`p_${k}`] = v

  try {
    const response = await fetch(`http://rest:3000/rpc/${rpcName}`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${jwt}`,
        apikey: anonKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(rpcBody),
    })
    return new Response(await response.text(), {
      status: response.status,
      headers: { 'Content-Type': 'application/json' },
    })
  } catch (err: any) {
    return errorResponse('internal_error', `RPC proxy error: ${err.message}`, 502)
  }
}

// ── Documentation endpoints ─────────────────────────────────────────────────

function serveSwaggerUI(): Response {
  const publicUrl = Deno.env.get('PUBLIC_SUPABASE_URL') || Deno.env.get('SUPABASE_URL') || ''
  const specUrl = `${publicUrl}/api/v1/openapi.yaml`

  // NOTE: v1 loads Swagger UI from CDN (unpkg.com). On-premise installations
  // without internet will see a broken docs page. Future: bundle assets locally.
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>VMflow API v1</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
  <style>body { margin: 0; } .topbar { display: none; }</style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    SwaggerUIBundle({
      url: '${specUrl}',
      dom_id: '#swagger-ui',
      deepLinking: true,
      presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],
      layout: 'BaseLayout',
    })
  </script>
</body>
</html>`

  return new Response(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  })
}

function serveOpenApiSpec(): Response {
  // Read the spec file from the function directory
  try {
    const spec = Deno.readTextFileSync(new URL('./openapi.yaml', import.meta.url).pathname)
    return new Response(spec, {
      headers: {
        'Content-Type': 'text/yaml; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
      },
    })
  } catch (_) {
    return errorResponse('not_found', 'OpenAPI spec not found', 404)
  }
}
