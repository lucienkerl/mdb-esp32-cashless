package xyz.vmflow.data

import kotlinx.datetime.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import xyz.vmflow.models.MdbDiagnostics
import kotlin.math.roundToInt

/**
 * Which network a device is on and how good its signal is, from
 * `embeddeds.mdb_diagnostics`.
 *
 * 1:1 port of the web's `management-frontend/app/lib/network.ts` and iOS
 * `Models/DeviceNetwork.swift`; `DeviceNetworkTest` runs the web's test cases.
 * The mqtt-webhook writes the uplink into `network` (WiFi or cellular, with
 * `measured_at`); the older `cellular` block is read as a fallback. Both are
 * read as raw JSON so an unexpected field type never breaks the machine list.
 */
data class DeviceNetwork(
    val kind: Kind,
    /** SSID on WiFi, operator on cellular. */
    val name: String?,
    val rssi: Int?,
    /** 0–4 bars / arcs; null when no signal value is known. */
    val level: Int?,
    val quality: Quality?,
    val tone: Tone?,
    /** Radio mode on cellular (LTE-M, NB-IoT …). */
    val mode: String?,
    val ip: String?,
    /** When the signal was last sampled; null for the legacy `cellular` block. */
    val measuredAt: Instant?,
) {
    enum class Kind { WIFI, CELLULAR }
    enum class Quality { EXCELLENT, GOOD, FAIR, WEAK, NONE }
    /** How the signal is painted: only weak and none draw attention. */
    enum class Tone { OK, WEAK, BAD }

    val isWeak: Boolean get() = tone == Tone.WEAK || tone == Tone.BAD

    companion object {
        /** Lower dBm limit for 4, 3, 2 and 1 bars. */
        fun thresholds(kind: Kind): IntArray = when (kind) {
            Kind.WIFI -> intArrayOf(-55, -67, -75, -85)
            Kind.CELLULAR -> intArrayOf(-65, -80, -95, -105)
        }

        fun level(kind: Kind, rssi: Int?): Int? {
            // 0 dBm is what the firmware reports when it has no reading.
            if (rssi == null || rssi >= 0) return null
            val t = thresholds(kind)
            return when {
                rssi >= t[0] -> 4
                rssi >= t[1] -> 3
                rssi >= t[2] -> 2
                rssi >= t[3] -> 1
                else -> 0
            }
        }

        fun quality(level: Int?): Quality? = when (level) {
            null -> null
            else -> listOf(Quality.NONE, Quality.WEAK, Quality.FAIR, Quality.GOOD, Quality.EXCELLENT)[level.coerceIn(0, 4)]
        }

        fun tone(level: Int?): Tone? = when {
            level == null -> null
            level >= 2 -> Tone.OK
            level == 1 -> Tone.WEAK
            else -> Tone.BAD
        }

        private fun JsonObject.str(key: String): String? {
            val p = this[key] as? JsonPrimitive ?: return null
            if (!p.isString) return null
            val s = p.content.trim()
            return s.takeIf { it.isNotEmpty() && it != "unknown" && it != "0.0.0.0" && it != "?" }
        }

        private fun JsonObject.int(key: String): Int? {
            val p = this[key] as? JsonPrimitive ?: return null
            if (p.isString) return null
            return p.intOrNull ?: p.doubleOrNull?.takeIf { it.isFinite() }?.roundToInt()
        }

        private fun JsonElement?.uplink(): String? = ((this as? JsonObject)?.get("uplink") as? JsonPrimitive)
            ?.takeIf { it.isString }?.content

        fun from(network: JsonElement?, cellular: JsonElement?): DeviceNetwork? {
            val block: JsonObject = when {
                network.uplink() == "wifi" || network.uplink() == "cellular" -> network as JsonObject
                cellular.uplink() == "cellular" -> cellular as JsonObject
                else -> return null
            }
            val kind = if (block.uplink() == "wifi") Kind.WIFI else Kind.CELLULAR
            val rssi = block.int("rssi")
            val level = level(kind, rssi)
            val measured = block.str("measured_at")?.let { runCatching { Instant.parse(it) }.getOrNull() }
            return DeviceNetwork(
                kind = kind,
                name = if (kind == Kind.WIFI) block.str("ssid") else block.str("op"),
                rssi = if (level == null) null else rssi,
                level = level,
                quality = quality(level),
                tone = tone(level),
                mode = if (kind == Kind.CELLULAR) block.str("mode") else null,
                ip = block.str("ip"),
                measuredAt = measured,
            )
        }
    }
}

/** Which network the device is on and how good its signal is. */
val MdbDiagnostics?.deviceNetwork: DeviceNetwork?
    get() = this?.let { DeviceNetwork.from(it.network, it.cellular) }
