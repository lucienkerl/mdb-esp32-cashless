import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts"

const FUNC_URL = "http://127.0.0.1:54321/functions/v1/sync-softap-password"

async function hmac(key: string, msg: string): Promise<string> {
  const enc = new TextEncoder()
  const k = await crypto.subtle.importKey(
    "raw", enc.encode(key),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  )
  const s = await crypto.subtle.sign("HMAC", k, enc.encode(msg))
  return Array.from(new Uint8Array(s))
    .map(b => b.toString(16).padStart(2, "0")).join("")
}

const DEVICE_ID = Deno.env.get("TEST_DEVICE_ID") ?? ""
const MAC = Deno.env.get("TEST_DEVICE_MAC") ?? ""
const PASSKEY = Deno.env.get("TEST_DEVICE_PASSKEY") ?? ""

const haveFixture = DEVICE_ID && MAC && PASSKEY

Deno.test({
  name: "valid signature → 200 with softap_password",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000)
    const sig = await hmac(PASSKEY, `${DEVICE_ID}|${MAC}|${ts}`)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: MAC, timestamp: ts, signature: sig }),
    })
    assertEquals(res.status, 200)
    const data = await res.json()
    assertEquals(typeof data.softap_password, "string")
    assertEquals(data.softap_password.length, 12)
  },
})

Deno.test({
  name: "wrong signature → 401",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: MAC, timestamp: ts, signature: "deadbeef".repeat(8) }),
    })
    assertEquals(res.status, 401)
  },
})

Deno.test({
  name: "stale timestamp → 401",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000) - 3600
    const sig = await hmac(PASSKEY, `${DEVICE_ID}|${MAC}|${ts}`)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: MAC, timestamp: ts, signature: sig }),
    })
    assertEquals(res.status, 401)
  },
})

Deno.test({
  name: "mac mismatch → 401",
  ignore: !haveFixture,
  fn: async () => {
    const ts = Math.floor(Date.now() / 1000)
    const wrongMac = "00:00:00:00:00:00"
    const sig = await hmac(PASSKEY, `${DEVICE_ID}|${wrongMac}|${ts}`)
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: DEVICE_ID, mac_address: wrongMac, timestamp: ts, signature: sig }),
    })
    assertEquals(res.status, 401)
  },
})

Deno.test({
  name: "missing field → 400",
  fn: async () => {
    const res = await fetch(FUNC_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ device_id: "x" }),
    })
    assertEquals(res.status, 400)
  },
})
