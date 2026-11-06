package xyz.vmflow.data

import kotlinx.datetime.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import xyz.vmflow.models.MdbDiagnostics

/**
 * Network + signal of a device. Same cases as the web's
 * `lib/__tests__/network.test.ts` and iOS `HostTests/DeviceNetwork`.
 */
class DeviceNetworkTest {

    private fun json(s: String): JsonElement = Json.parseToJsonElement(s)

    @Test fun wifiLevels() {
        listOf(-40 to 4, -55 to 4, -56 to 3, -67 to 3, -68 to 2, -75 to 2, -76 to 1, -85 to 1, -86 to 0, -100 to 0)
            .forEach { (rssi, level) -> assertEquals("wifi $rssi", level, DeviceNetwork.level(DeviceNetwork.Kind.WIFI, rssi)) }
    }

    @Test fun cellularLevels() {
        listOf(-50 to 4, -65 to 4, -66 to 3, -80 to 3, -81 to 2, -95 to 2, -96 to 1, -105 to 1, -106 to 0)
            .forEach { (rssi, level) -> assertEquals("cellular $rssi", level, DeviceNetwork.level(DeviceNetwork.Kind.CELLULAR, rssi)) }
    }

    @Test fun noLevelWithoutReading() {
        assertNull(DeviceNetwork.level(DeviceNetwork.Kind.WIFI, null))
        assertNull(DeviceNetwork.level(DeviceNetwork.Kind.WIFI, 0))
    }

    @Test fun qualityAndTone() {
        assertEquals(
            listOf(DeviceNetwork.Quality.NONE, DeviceNetwork.Quality.WEAK, DeviceNetwork.Quality.FAIR, DeviceNetwork.Quality.GOOD, DeviceNetwork.Quality.EXCELLENT),
            (0..4).map { DeviceNetwork.quality(it) },
        )
        assertEquals(
            listOf(DeviceNetwork.Tone.BAD, DeviceNetwork.Tone.WEAK, DeviceNetwork.Tone.OK, DeviceNetwork.Tone.OK, DeviceNetwork.Tone.OK),
            (0..4).map { DeviceNetwork.tone(it) },
        )
        assertNull(DeviceNetwork.quality(null))
    }

    @Test fun nullWithoutUplink() {
        assertNull(DeviceNetwork.from(null, null))
        assertNull(MdbDiagnostics(state = "IDLE").deviceNetwork)
        assertNull(DeviceNetwork.from(json("""{"uplink":"none"}"""), null))
    }

    @Test fun wifiBlock() {
        val n = DeviceNetwork.from(
            json("""{"uplink":"wifi","ssid":"Büro-WLAN","rssi":-62,"ip":"192.168.1.47","measured_at":"2026-11-06T12:00:00.000Z"}"""),
            null,
        )
        assertEquals(
            DeviceNetwork(
                kind = DeviceNetwork.Kind.WIFI, name = "Büro-WLAN", rssi = -62, level = 3,
                quality = DeviceNetwork.Quality.GOOD, tone = DeviceNetwork.Tone.OK, mode = null,
                ip = "192.168.1.47", measuredAt = Instant.parse("2026-11-06T12:00:00Z"),
            ),
            n,
        )
    }

    @Test fun cellularBlock() {
        val n = DeviceNetwork.from(json("""{"uplink":"cellular","op":"Telekom.de","rssi":-78,"mode":"LTE-M","ip":"10.0.0.1"}"""), null)!!
        assertEquals(DeviceNetwork.Kind.CELLULAR, n.kind)
        assertEquals("Telekom.de", n.name)
        assertEquals("LTE-M", n.mode)
        assertEquals(3, n.level)
    }

    @Test fun legacyCellularFallback() {
        val n = MdbDiagnostics(cellular = json("""{"uplink":"cellular","op":"Vodafone DE","rssi":-100,"mode":"NB-IoT"}""")).deviceNetwork!!
        assertEquals("Vodafone DE", n.name)
        assertEquals(DeviceNetwork.Tone.WEAK, n.tone)
        assertNull(n.measuredAt)
    }

    @Test fun networkBlockWins() {
        val n = DeviceNetwork.from(
            json("""{"uplink":"wifi","ssid":"Office","rssi":-90}"""),
            json("""{"uplink":"cellular","op":"Telekom.de","rssi":-70}"""),
        )!!
        assertEquals(DeviceNetwork.Kind.WIFI, n.kind)
        assertEquals(DeviceNetwork.Tone.BAD, n.tone)
    }

    @Test fun placeholdersAreUnknown() {
        val n = DeviceNetwork.from(json("""{"uplink":"cellular","op":"unknown","ip":"0.0.0.0","mode":"?","rssi":0}"""), null)!!
        assertNull(n.name)
        assertNull(n.ip)
        assertNull(n.mode)
        assertNull(n.rssi)
        assertNull(n.level)
    }

    @Test fun lenientFieldTypes() {
        val n = DeviceNetwork.from(json("""{"uplink":"wifi","ssid":42,"rssi":-61.6}"""), null)!!
        assertNull(n.name)
        assertEquals(-62, n.rssi)
    }
}
