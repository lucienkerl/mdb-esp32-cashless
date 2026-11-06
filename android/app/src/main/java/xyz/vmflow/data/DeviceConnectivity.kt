package xyz.vmflow.data

import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import xyz.vmflow.models.Embedded
import xyz.vmflow.models.VendingMachineWithEmbedded
import kotlin.math.roundToLong
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes

/**
 * Device connectivity: one definition of "online" for the whole app.
 *
 * 1:1 port of the web's `management-frontend/app/lib/connectivity.ts` and
 * iOS `Models/DeviceConnectivity.swift`; `DeviceConnectivityTest` runs the
 * web's test cases. Keep the three in step.
 *
 * `status` is "online" when the device connects, "offline" from the broker's
 * Last Will when the connection drops, plus the OTA states. `status_at` moves
 * with every status message and with the 5-minute mdb-log heartbeat. The Last
 * Will does not always arrive, so "online" is trusted only while heartbeats
 * come: after [STALE_AFTER] without one the device is [ConnectivityState.STALE]
 * — two missed heartbeats plus margin, so one lost heartbeat never flips a
 * running device. (The old rule here, "online and status_at < 5 min", equalled
 * the heartbeat interval and showed running devices as offline.)
 */
enum class ConnectivityState { ONLINE, STALE, OFFLINE, UPDATING, NEVER, NONE }

/** Can the machine sell cashless? From `mdb_diagnostics.state`, the LED's second axis. */
enum class ReaderState {
    READY, DISABLED, INACTIVE;

    companion object {
        fun fromMdbState(state: String?): ReaderState? = when (state?.uppercase()) {
            "ENABLED", "IDLE", "VEND" -> READY
            "DISABLED" -> DISABLED
            "INACTIVE" -> INACTIVE
            else -> null
        }
    }
}

data class DeviceConnectivity(
    val state: ConnectivityState,
    /** Last time the device was heard from (`status_at`), if ever. */
    val lastContactAt: Instant?,
    /** The moment the state's time label refers to: online → online since, offline → offline since, updating → update started, stale → last contact. */
    val since: Instant?,
    /** Start of the current (or, when offline, the last) online run. */
    val onlineSince: Instant?,
    /** Only set while the device is online and has reported an MDB state. */
    val reader: ReaderState?,
) {
    /** Offline, no answer, or online but the machine does not talk to the reader. */
    val needsAttention: Boolean
        get() = state == ConnectivityState.OFFLINE || state == ConnectivityState.STALE ||
            (state == ConnectivityState.ONLINE && reader == ReaderState.INACTIVE)

    /** Connected right now (online or installing an update). */
    val isConnected: Boolean
        get() = state == ConnectivityState.ONLINE || state == ConnectivityState.UPDATING

    /** Sort key: what needs attention first, machines without a device last. */
    val rank: Int
        get() = when (state) {
            ConnectivityState.OFFLINE -> 0
            ConnectivityState.STALE -> 1
            ConnectivityState.ONLINE -> if (reader == ReaderState.INACTIVE) 2 else 4
            ConnectivityState.UPDATING -> 3
            ConnectivityState.NEVER -> 5
            ConnectivityState.NONE -> 6
        }

    companion object {
        val STALE_AFTER: Duration = 12.minutes
        /** An update that has not finished (reboot + "online") by then is treated as stale. */
        val UPDATE_STALE_AFTER: Duration = 10.minutes

        val NO_DEVICE = DeviceConnectivity(ConnectivityState.NONE, null, null, null, null)

        private fun parse(iso: String?): Instant? = iso?.let { runCatching { Instant.parse(it) }.getOrNull() }

        fun evaluate(
            status: String?,
            statusAt: String?,
            onlineSince: String?,
            mdbState: String?,
            now: Instant = Clock.System.now(),
        ): DeviceConnectivity {
            val s = status?.trim()?.lowercase().orEmpty()
            val lastContact = parse(statusAt)
            val runStart = parse(onlineSince)
            val age: Duration = lastContact?.let { now - it } ?: Duration.INFINITE

            if (s.isEmpty()) return DeviceConnectivity(ConnectivityState.NEVER, lastContact, null, null, null)
            if (s == "offline") return DeviceConnectivity(ConnectivityState.OFFLINE, lastContact, lastContact, runStart, null)
            if (s == "ota_updating" && age <= UPDATE_STALE_AFTER) {
                return DeviceConnectivity(ConnectivityState.UPDATING, lastContact, lastContact, runStart, null)
            }
            // "online", "ota_success", "ota_failed" (the device keeps running) and any
            // status this version does not know: trusted only while heartbeats come.
            if (s != "ota_updating" && age <= STALE_AFTER) {
                return DeviceConnectivity(ConnectivityState.ONLINE, lastContact, runStart, runStart, ReaderState.fromMdbState(mdbState))
            }
            return DeviceConnectivity(ConnectivityState.STALE, lastContact, lastContact, runStart, null)
        }
    }
}

fun Embedded?.connectivity(now: Instant = Clock.System.now()): DeviceConnectivity =
    if (this == null) DeviceConnectivity.NO_DEVICE
    else DeviceConnectivity.evaluate(status, statusAt, onlineSince, mdbDiagnostics?.state, now)

fun VendingMachineWithEmbedded.connectivity(now: Instant = Clock.System.now()): DeviceConnectivity =
    embeddeds.connectivity(now)

data class FleetConnectivity(
    /** Devices that are connected: online plus updating. */
    val online: Int = 0,
    val stale: Int = 0,
    val offline: Int = 0,
    val updating: Int = 0,
    val never: Int = 0,
    /** Machines without a device: not counted as devices at all. */
    val none: Int = 0,
    val devices: Int = 0,
    val readerInactive: Int = 0,
    val attention: Int = 0,
) {
    companion object {
        fun of(items: List<DeviceConnectivity>): FleetConnectivity {
            val withDevice = items.filter { it.state != ConnectivityState.NONE }
            return FleetConnectivity(
                online = withDevice.count { it.isConnected },
                stale = withDevice.count { it.state == ConnectivityState.STALE },
                offline = withDevice.count { it.state == ConnectivityState.OFFLINE },
                updating = withDevice.count { it.state == ConnectivityState.UPDATING },
                never = withDevice.count { it.state == ConnectivityState.NEVER },
                none = items.size - withDevice.size,
                devices = withDevice.size,
                readerInactive = withDevice.count { it.state == ConnectivityState.ONLINE && it.reader == ReaderState.INACTIVE },
                attention = withDevice.count { it.needsAttention },
            )
        }
    }
}

/** Whole days, hours and minutes of a duration (units come from the caller). */
data class DurationParts(val days: Long, val hours: Long, val minutes: Long) {
    companion object {
        fun of(duration: Duration): DurationParts {
            val total = duration.inWholeMinutes.coerceAtLeast(0)
            return DurationParts(total / 1440, (total % 1440) / 60, total % 60)
        }
    }
}

// ─── 24-hour history ────────────────────────────────────────────────────────

/** One status change from `embedded_status_log`. */
@Serializable
data class StatusLogRow(
    val status: String,
    @SerialName("prev_status") val prevStatus: String? = null,
    @SerialName("created_at") val createdAt: String,
)

enum class SegmentState {
    ONLINE, OFFLINE, UPDATING, UNKNOWN;

    companion object {
        fun of(status: String?): SegmentState {
            val s = status?.trim()?.lowercase().orEmpty()
            return when {
                s.isEmpty() -> UNKNOWN
                s == "offline" -> OFFLINE
                s == "ota_updating" -> UPDATING
                else -> ONLINE
            }
        }
    }
}

data class StatusSegment(val state: SegmentState, val start: Instant, val end: Instant)

data class StatusHistory(
    val segments: List<StatusSegment>,
    /** Share of the known time the device was connected, 0-100 (one decimal), null if nothing is known. */
    val onlinePercent: Double?,
    /** Offline stretches inside the window, oldest first. */
    val outages: List<StatusSegment>,
) {
    companion object {
        /**
         * Rows inside the window in any order; the state before the first
         * change is that row's `prevStatus`, without any change it is the
         * current status. Adjacent segments with the same state are merged.
         */
        fun build(rows: List<StatusLogRow>, currentStatus: String?, windowStart: Instant, now: Instant): StatusHistory {
            val sorted = rows
                .mapNotNull { r -> runCatching { Instant.parse(r.createdAt) }.getOrNull()?.let { r to it } }
                .filter { (_, at) -> at >= windowStart && at <= now }
                .sortedBy { it.second }

            val segments = mutableListOf<StatusSegment>()
            fun push(state: SegmentState, start: Instant, end: Instant) {
                if (end <= start) return
                val last = segments.lastOrNull()
                if (last != null && last.state == state && last.end == start) {
                    segments[segments.size - 1] = last.copy(end = end)
                } else {
                    segments += StatusSegment(state, start, end)
                }
            }

            var state = sorted.firstOrNull()?.let { SegmentState.of(it.first.prevStatus) } ?: SegmentState.of(currentStatus)
            var cursor = windowStart
            for ((row, at) in sorted) {
                push(state, cursor, at)
                state = SegmentState.of(row.status)
                cursor = at
            }
            push(state, cursor, now)

            var known = 0L
            var connected = 0L
            for (seg in segments) {
                val len = (seg.end - seg.start).inWholeMilliseconds
                if (seg.state != SegmentState.UNKNOWN) known += len
                if (seg.state == SegmentState.ONLINE || seg.state == SegmentState.UPDATING) connected += len
            }
            val percent = if (known > 0) (connected.toDouble() / known * 1000).roundToLong() / 10.0 else null
            return StatusHistory(segments, percent, segments.filter { it.state == SegmentState.OFFLINE })
        }
    }
}
