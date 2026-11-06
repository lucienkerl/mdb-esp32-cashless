// Checks the SHA-256 / HMAC-SHA256 the captive portal ships (webui/index.html,
// between the "BEGIN sha256" / "END sha256" markers) against Node's crypto:
// RFC 4231 test vectors, random keys/messages of every length around the
// block boundaries, and the exact request-signing layout of wa_verify() in
// main/webui_auth.h.
//
//   node hmac_interop.mjs
import { readFileSync } from 'node:fs'
import { createHmac, createHash, randomBytes } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import vm from 'node:vm'

const here = dirname(fileURLToPath(import.meta.url))
const html = readFileSync(join(here, '../../webui/index.html'), 'utf8')
const m = html.match(/\/\* BEGIN sha256 \*\/([\s\S]*?)\/\* END sha256 \*\//)
if (!m) throw new Error('sha256 markers not found in index.html')

const ctx = { TextEncoder, Uint8Array, Math }
vm.createContext(ctx)
vm.runInContext(m[1], ctx)
const { sha256, hmacSha256, signRequest, utf8Bytes, bytesToHex } = ctx

let failures = 0
function check(cond, what) {
  if (!cond) { failures++; console.error('FAIL', what) }
}
const hex = (b) => Buffer.from(b).toString('hex')

// RFC 4231 HMAC-SHA256 vectors
const rfc = [
  ['0b'.repeat(20), Buffer.from('Hi There').toString('hex'),
   'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7'],
  [Buffer.from('Jefe').toString('hex'), Buffer.from('what do ya want for nothing?').toString('hex'),
   '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843'],
  ['aa'.repeat(20), 'dd'.repeat(50),
   '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe'],
  ['aa'.repeat(131), Buffer.from('Test Using Larger Than Block-Size Key - Hash Key First').toString('hex'),
   '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54'],
]
for (const [k, d, want] of rfc) {
  check(hex(hmacSha256(Buffer.from(k, 'hex'), Buffer.from(d, 'hex'))) === want, `RFC 4231 ${want.slice(0, 8)}`)
}

// SHA-256 at every length 0..300 (covers the 55/56/64-byte padding edges)
for (let n = 0; n <= 300; n++) {
  const data = randomBytes(n)
  check(hex(sha256(new Uint8Array(data))) === createHash('sha256').update(data).digest('hex'), `sha256 len ${n}`)
}

// HMAC with random keys (incl. > block size) and messages
for (let i = 0; i < 300; i++) {
  const key = randomBytes(i % 150)
  const msg = randomBytes((i * 7) % 700)
  check(hex(hmacSha256(new Uint8Array(key), new Uint8Array(msg))) ===
        createHmac('sha256', key).update(msg).digest('hex'), `hmac case ${i}`)
}

// Request signature layout = wa_verify(): nonce \n METHOD \n path \n body,
// key and message UTF-8 encoded
const nonce = '0123456789abcdef0123456789abcdef'
const cases = [
  ['Kp7mQx2RtW9z', 'POST', '/api/v1/system/reset', '{}'],
  ['Kp7mQx2RtW9z', 'GET', '/api/v1/wifi/scan', undefined],
  ['Kp7mQx2RtW9z', 'POST', '/api/v1/wifi/configure', JSON.stringify({ ssid: 'Café Wi‑Fi ☕', password: 'pä$$' })],
]
for (const [pwd, method, path, body] of cases) {
  const want = createHmac('sha256', Buffer.from(pwd, 'utf8'))
    .update(Buffer.from(`${nonce}\n${method}\n${path}\n${body ?? ''}`, 'utf8')).digest('hex')
  check(signRequest(pwd, nonce, method, path, body) === want, `signRequest ${method} ${path}`)
}
check(bytesToHex(utf8Bytes('é')) === 'c3a9', 'utf8Bytes')

if (failures) {
  console.error(`${failures} check(s) failed`)
  process.exit(1)
}
console.log('webui sha256/hmac: all interop checks passed')
