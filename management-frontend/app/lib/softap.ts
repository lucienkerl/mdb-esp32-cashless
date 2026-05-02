/**
 * Compute the SoftAP SSID for a device given its MAC address.
 * Mirrors firmware logic in mdb-slave-esp32s3/main/webui_server.c::softap_get_ssid.
 *
 * Format: "VMflow-XXXXXX" where XXXXXX is the last 3 bytes of the MAC in
 * uppercase hex. Falls back to "VMflow-?" if the MAC is missing or malformed.
 */
export function computeSoftApSsid(mac: string | null | undefined): string {
  if (!mac) return 'VMflow-?'
  const hex = mac.replace(/[^0-9a-fA-F]/g, '').toUpperCase()
  if (hex.length !== 12) return 'VMflow-?'
  return `VMflow-${hex.slice(6, 12)}`
}

/**
 * Build a WPA WiFi-QR payload per the de-facto MeCard-style standard supported
 * by iOS Camera, Android Camera, and most QR scanner apps. Escapes \ ; , " : per spec.
 */
export function formatWifiQrPayload(ssid: string, password: string): string {
  const escape = (s: string) => s.replace(/[\\;,":]/g, c => `\\${c}`)
  return `WIFI:T:WPA;S:${escape(ssid)};P:${escape(password)};;`
}
