package xyz.vmflow.data

import kotlinx.datetime.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import xyz.vmflow.models.Embedded
import xyz.vmflow.models.MdbDiagnostics
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds

/**
 * Device connectivity. Same cases as the web's `lib/__tests__/connectivity.test.ts`
 * and iOS `HostTests/Connectivity`.
 */
class DeviceConnectivityTest {

    private val now = Instant.parse("2026-11-04T16:00:00Z")
    private fun minAgo(m: Int): String = (now - m.minutes).toString()

    private fun eval(status: String?, statusAt: String?, onlineSince: String? = null, mdb: String? = null) =
        DeviceConnectivity.evaluate(status, statusAt, onlineSince, mdb, now)

    @Test fun noneForMachineWithoutDevice() {
        val c = (null as Embedded?).connectivity(now)
        assertEquals(ConnectivityState.NONE, c.state)
        assertFalse(c.needsAttention)
    }

    @Test fun neverForDeviceWithoutStatus() {
        assertEquals(ConnectivityState.NEVER, eval(null, null).state)
        assertEquals(ConnectivityState.NEVER, eval("", minAgo(1)).state)
    }

    @Test fun onlineWhileHeartbeatsArrive() {
        val c = eval("online", minAgo(2), minAgo(600))
        assertEquals(ConnectivityState.ONLINE, c.state)
        assertEquals(Instant.parse(minAgo(2)), c.lastContactAt)
        assertEquals(Instant.parse(minAgo(600)), c.since)
        assertFalse(c.needsAttention)
    }

    @Test fun survivesOneLostHeartbeat() {
        assertEquals(ConnectivityState.ONLINE, eval("online", minAgo(10)).state)
        assertEquals(ConnectivityState.ONLINE, eval("online", minAgo(12)).state)
    }

    @Test fun staleWhenSilentForMoreThan12Minutes() {
        val c = eval("online", minAgo(13))
        assertEquals(ConnectivityState.STALE, c.state)
        assertEquals(Instant.parse(minAgo(13)), c.since)
        assertTrue(c.needsAttention)
        assertEquals(ConnectivityState.STALE, eval("online", null).state)
    }

    @Test fun offlineWithTheTimeTheDropWasNoticed() {
        val c = eval("offline", minAgo(120), minAgo(9000))
        assertEquals(ConnectivityState.OFFLINE, c.state)
        assertEquals(Instant.parse(minAgo(120)), c.since)
        assertEquals(Instant.parse(minAgo(9000)), c.onlineSince)
        assertTrue(c.needsAttention)
        assertEquals(ConnectivityState.OFFLINE, eval("OFFLINE", minAgo(1)).state)
    }

    @Test fun updatingThenStaleOnceItHangs() {
        assertEquals(ConnectivityState.UPDATING, eval("ota_updating", minAgo(3)).state)
        assertEquals(ConnectivityState.STALE, eval("ota_updating", minAgo(11)).state)
    }

    @Test fun finishedOrFailedUpdatesCountAsOnline() {
        assertEquals(ConnectivityState.ONLINE, eval("ota_success", minAgo(1)).state)
        assertEquals(ConnectivityState.ONLINE, eval("ota_failed", minAgo(1)).state)
    }

    @Test fun readerStateOnlyWhileOnline() {
        val ready = eval("online", minAgo(1), mdb = "IDLE")
        assertEquals(ReaderState.READY, ready.reader)
        assertFalse(ready.needsAttention)

        val silent = eval("online", minAgo(1), mdb = "INACTIVE")
        assertEquals(ReaderState.INACTIVE, silent.reader)
        assertTrue(silent.needsAttention)

        assertNull(eval("offline", minAgo(1), mdb = "IDLE").reader)
    }

    @Test fun mapsMdbStates() {
        assertEquals(ReaderState.READY, ReaderState.fromMdbState("ENABLED"))
        assertEquals(ReaderState.READY, ReaderState.fromMdbState("VEND"))
        assertEquals(ReaderState.DISABLED, ReaderState.fromMdbState("DISABLED"))
        assertEquals(ReaderState.INACTIVE, ReaderState.fromMdbState("INACTIVE"))
        assertNull(ReaderState.fromMdbState("UNKNOWN"))
        assertNull(ReaderState.fromMdbState(null))
    }

    @Test fun embeddedExtensionReadsMdbDiagnostics() {
        val e = Embedded(id = "e1", status = "online", statusAt = minAgo(1), mdbDiagnostics = MdbDiagnostics(state = "INACTIVE"))
        assertEquals(ReaderState.INACTIVE, e.connectivity(now).reader)
    }

    @Test fun fleetCountsDevicesAndLeavesMachinesWithoutDeviceOut() {
        val s = FleetConnectivity.of(
            listOf(
                eval("online", minAgo(1)),
                eval("online", minAgo(1), mdb = "INACTIVE"),
                eval("ota_updating", minAgo(1)),
                eval("online", minAgo(47)),
                eval("offline", minAgo(120)),
                eval(null, null),
                DeviceConnectivity.NO_DEVICE,
            )
        )
        assertEquals(
            FleetConnectivity(online = 3, stale = 1, offline = 1, updating = 1, never = 1, none = 1, devices = 6, readerInactive = 1, attention = 3),
            s
        )
    }

    @Test fun rankSortsProblemsFirstAndNoDeviceLast() {
        val ordered = listOf(
            DeviceConnectivity.NO_DEVICE,
            eval("online", minAgo(1)),
            eval("offline", minAgo(1)),
            eval("online", minAgo(30)),
            eval("online", minAgo(1), mdb = "INACTIVE"),
        ).sortedBy { it.rank }.map { "${it.state}:${it.reader ?: ""}" }
        assertEquals(listOf("OFFLINE:", "STALE:", "ONLINE:INACTIVE", "ONLINE:", "NONE:"), ordered)
    }

    @Test fun durationParts() {
        assertEquals(DurationParts(3, 4, 5), DurationParts.of((3 * 1440 + 4 * 60 + 5).minutes))
        assertEquals(DurationParts(0, 0, 0), DurationParts.of(59.seconds))
        assertEquals(DurationParts(0, 0, 0), DurationParts.of((-5).seconds))
    }

    // ─── 24-hour history ────────────────────────────────────────────────

    private val start = now - 24.hours
    private fun at(h: Double): Instant = start + (h * 3600).seconds
    private fun row(status: String, prev: String?, h: Double) = StatusLogRow(status, prev, at(h).toString())

    @Test fun oneSegmentWithoutChanges() {
        val h = StatusHistory.build(emptyList(), "online", start, now)
        assertEquals(listOf(StatusSegment(SegmentState.ONLINE, start, now)), h.segments)
        assertEquals(100.0, h.onlinePercent!!, 0.0)
        assertTrue(h.outages.isEmpty())
    }

    @Test fun splitsAtEveryChange() {
        val h = StatusHistory.build(
            listOf(
                row("online", "offline", 12.75),
                row("offline", "online", 12.0),
                row("ota_updating", "online", 18.0),
                row("online", "ota_updating", 18.25),
            ),
            "online", start, now
        )
        assertEquals(
            listOf(SegmentState.ONLINE, SegmentState.OFFLINE, SegmentState.ONLINE, SegmentState.UPDATING, SegmentState.ONLINE),
            h.segments.map { it.state }
        )
        assertEquals(listOf(StatusSegment(SegmentState.OFFLINE, at(12.0), at(12.75))), h.outages)
        assertEquals(96.9, h.onlinePercent!!, 0.0)
    }

    @Test fun mergesRepeatedStatesAndLeavesUnknownOut() {
        val h = StatusHistory.build(
            listOf(row("online", null, 12.0), row("ota_success", "online", 13.0)),
            "ota_success", start, now
        )
        assertEquals(
            listOf(StatusSegment(SegmentState.UNKNOWN, start, at(12.0)), StatusSegment(SegmentState.ONLINE, at(12.0), now)),
            h.segments
        )
        assertEquals(100.0, h.onlinePercent!!, 0.0)
    }

    @Test fun ignoresRowsOutsideTheWindow() {
        val h = StatusHistory.build(
            listOf(StatusLogRow("offline", "online", (start - 1.hours).toString())),
            "offline", start, now
        )
        assertEquals(listOf(StatusSegment(SegmentState.OFFLINE, start, now)), h.segments)
        assertEquals(0.0, h.onlinePercent!!, 0.0)
    }
}
