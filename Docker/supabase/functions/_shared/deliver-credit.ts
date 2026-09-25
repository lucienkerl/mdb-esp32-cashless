/**
 * Shared credit delivery helper — builds XOR-encrypted MDB credit payload
 * and publishes via MQTT. Same logic as send-credit/index.ts.
 */
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { mqttPublish } from './mqtt-publish.ts'
import { eurToScaleUnits } from './scale.ts'

/**
 * Deliver credit to a vending machine via MQTT.
 * @param companyId - Company UUID (for MQTT topic)
 * @param deviceId - Embedded device UUID (for MQTT topic)
 * @param passkey - Device passkey string (for XOR encryption)
 * @param amountEur - Amount in EUR (e.g., 2.50)
 * @param opts.closeCardSession - default true. Credit from anywhere other
 *   than an RFID card replaces whatever the machine was holding, so any open
 *   card session has to go with it: otherwise the vend it pays for would be
 *   charged back to whoever tapped their card last. mqtt-webhook's own card
 *   handler passes false — it opens the session itself.
 */
export async function deliverCredit(
  companyId: string,
  deviceId: string,
  passkey: string,
  amountEur: number,
  opts: { closeCardSession?: boolean } = {},
): Promise<void> {
  const cipher: number[] = [...passkey].map((c: string) => c.charCodeAt(0))

  const payload = new Uint8Array(19)
  crypto.getRandomValues(payload)

  const itemPrice = eurToScaleUnits(amountEur)
  const timestampSec = Math.floor(Date.now() / 1000)

  payload[0] = 0x20                            // cmd: credit
  payload[1] = 0x01                            // version v1
  payload[2] = (itemPrice >> 24) & 0xff        // itemPrice big-endian
  payload[3] = (itemPrice >> 16) & 0xff
  payload[4] = (itemPrice >> 8) & 0xff
  payload[5] = (itemPrice >> 0) & 0xff
  payload[6] = 0x00                            // itemNumber (unused for credit)
  payload[7] = 0x00
  payload[8] = (timestampSec >> 24) & 0xff     // timestamp big-endian
  payload[9] = (timestampSec >> 16) & 0xff
  payload[10] = (timestampSec >> 8) & 0xff
  payload[11] = (timestampSec >> 0) & 0xff

  // Checksum: sum of bytes 0..17
  const chk = payload.slice(0, -1).reduce((acc, val) => acc + val, 0)
  payload[payload.length - 1] = chk

  // XOR encrypt bytes [1..18] with passkey
  for (let k = 0; k < cipher.length; k++) {
    payload[k + 1] ^= cipher[k]
  }

  await mqttPublish(`/${companyId}/${deviceId}/credit`, payload, { qos: 1 })

  if (opts.closeCardSession !== false) {
    // Best-effort: a card-account bookkeeping problem must never make a paid
    // credit look undelivered to the caller.
    try {
      const adminClient = createClient(
        Deno.env.get('SUPABASE_URL')!,
        Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
      )
      await adminClient.rpc('card_session_close', {
        p_embedded_id: deviceId,
        p_reason: 'credit_replaced',
      })
    } catch (err) {
      console.error('card_session_close failed:', err)
    }
  }
}
