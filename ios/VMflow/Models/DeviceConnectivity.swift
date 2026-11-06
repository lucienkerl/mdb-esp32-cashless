import Foundation

/// Device connectivity: one definition of "online" for the whole app.
///
/// 1:1 port of the web's `management-frontend/app/lib/connectivity.ts`
/// (and Android's `data/DeviceConnectivity.kt`). Keep the three in step;
/// `ios/HostTests/Connectivity` runs the web test cases against this file.
///
/// `status` is "online" when the device connects, "offline" from the
/// broker's Last Will when the connection drops, plus the OTA states.
/// `statusAt` moves with every status message and with the 5-minute mdb-log
/// heartbeat. The Last Will does not always arrive, so "online" is trusted
/// only while heartbeats come: after `staleAfter` without one the device is
/// `.stale` (no answer, state unclear) — two missed heartbeats plus margin,
/// so one lost heartbeat never flips a running device.
enum ConnectivityState: String, Equatable {
    case online, stale, offline, updating, never, none
}

/// Can the machine sell cashless? From `mdb_diagnostics.state`, the LED's second axis.
enum ReaderState: String, Equatable {
    case ready, disabled, inactive

    init?(mdbState: String?) {
        switch mdbState?.uppercased() {
        case "ENABLED", "IDLE", "VEND": self = .ready
        case "DISABLED": self = .disabled
        case "INACTIVE": self = .inactive
        default: return nil
        }
    }
}

struct DeviceConnectivity: Equatable {
    static let staleAfter: TimeInterval = 12 * 60
    /// An update that has not finished (reboot + "online") by then is treated as stale.
    static let updateStaleAfter: TimeInterval = 10 * 60

    let state: ConnectivityState
    /// Last time the device was heard from (`status_at`), if ever.
    let lastContactAt: Date?
    /// The moment the state's time label refers to: online → online since,
    /// offline → offline since, updating → update started, stale → last contact.
    let since: Date?
    /// Start of the current (or, when offline, the last) online run.
    let onlineSince: Date?
    /// Only set while the device is online and has reported an MDB state.
    let reader: ReaderState?

    /// Offline, no answer, or online but the machine does not talk to the reader.
    var needsAttention: Bool {
        state == .offline || state == .stale || (state == .online && reader == .inactive)
    }

    /// Connected right now (online or installing an update).
    var isConnected: Bool { state == .online || state == .updating }

    static let noDevice = DeviceConnectivity(state: .none, lastContactAt: nil, since: nil, onlineSince: nil, reader: nil)

    static func evaluate(status rawStatus: String?, statusAt: Date?, onlineSince: Date?, mdbState: String?, now: Date = Date()) -> DeviceConnectivity {
        let status = (rawStatus ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let age = statusAt.map { now.timeIntervalSince($0) } ?? .infinity

        if status.isEmpty {
            return DeviceConnectivity(state: .never, lastContactAt: statusAt, since: nil, onlineSince: nil, reader: nil)
        }
        if status == "offline" {
            return DeviceConnectivity(state: .offline, lastContactAt: statusAt, since: statusAt, onlineSince: onlineSince, reader: nil)
        }
        if status == "ota_updating" && age <= updateStaleAfter {
            return DeviceConnectivity(state: .updating, lastContactAt: statusAt, since: statusAt, onlineSince: onlineSince, reader: nil)
        }
        // "online", "ota_success", "ota_failed" (the device keeps running) and any
        // status this version does not know: trusted only while heartbeats come.
        if status != "ota_updating" && age <= staleAfter {
            return DeviceConnectivity(state: .online, lastContactAt: statusAt, since: onlineSince, onlineSince: onlineSince, reader: ReaderState(mdbState: mdbState))
        }
        return DeviceConnectivity(state: .stale, lastContactAt: statusAt, since: statusAt, onlineSince: onlineSince, reader: nil)
    }

    /// Sort key: what needs attention first, machines without a device last.
    var rank: Int {
        switch state {
        case .offline: return 0
        case .stale: return 1
        case .online: return reader == .inactive ? 2 : 4
        case .updating: return 3
        case .never: return 5
        case .none: return 6
        }
    }
}

struct FleetConnectivity: Equatable {
    /// Devices that are connected: online plus updating.
    var online = 0
    var stale = 0
    var offline = 0
    var updating = 0
    var never = 0
    /// Machines without a device: not counted as devices at all.
    var none = 0
    var devices = 0
    var readerInactive = 0
    var attention = 0

    init() {}

    init(_ items: [DeviceConnectivity]) {
        for c in items {
            if c.state == .none { none += 1; continue }
            devices += 1
            if c.isConnected { online += 1 }
            switch c.state {
            case .updating: updating += 1
            case .stale: stale += 1
            case .offline: offline += 1
            case .never: never += 1
            default: break
            }
            if c.state == .online && c.reader == .inactive { readerInactive += 1 }
            if c.needsAttention { attention += 1 }
        }
    }
}

/// Splits a duration into whole days, hours and minutes (units come from the caller).
struct DurationParts: Equatable {
    let days: Int
    let hours: Int
    let minutes: Int

    init(_ interval: TimeInterval) {
        let total = max(0, Int(interval / 60))
        days = total / 1440
        hours = (total % 1440) / 60
        minutes = total % 60
    }

    init(days: Int, hours: Int, minutes: Int) {
        self.days = days
        self.hours = hours
        self.minutes = minutes
    }
}

// MARK: - 24-hour history

/// One status change from `embedded_status_log`.
struct StatusLogRow: Codable, Equatable {
    let status: String
    let prevStatus: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case status
        case prevStatus = "prev_status"
        case createdAt = "created_at"
    }
}

enum SegmentState: Equatable {
    case online, offline, updating, unknown

    init(status: String?) {
        let s = (status ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if s.isEmpty { self = .unknown }
        else if s == "offline" { self = .offline }
        else if s == "ota_updating" { self = .updating }
        else { self = .online }
    }
}

struct StatusSegment: Equatable {
    let state: SegmentState
    let start: Date
    var end: Date
}

struct StatusHistory: Equatable {
    let segments: [StatusSegment]
    /// Share of the known time the device was connected, 0-100 (one decimal), nil if nothing is known.
    let onlinePercent: Double?
    /// Offline stretches inside the window, oldest first.
    let outages: [StatusSegment]

    /// Rows inside the window in any order; the state before the first change
    /// is that row's `prevStatus`, without any change it is the current status.
    /// Adjacent segments with the same state are merged.
    static func build(rows: [StatusLogRow], currentStatus: String?, windowStart: Date, now: Date) -> StatusHistory {
        let sorted = rows
            .filter { $0.createdAt >= windowStart && $0.createdAt <= now }
            .sorted { $0.createdAt < $1.createdAt }

        var segments: [StatusSegment] = []
        func push(_ state: SegmentState, _ start: Date, _ end: Date) {
            guard end > start else { return }
            if var last = segments.last, last.state == state, last.end == start {
                last.end = end
                segments[segments.count - 1] = last
            } else {
                segments.append(StatusSegment(state: state, start: start, end: end))
            }
        }

        var state = sorted.first.map { SegmentState(status: $0.prevStatus) } ?? SegmentState(status: currentStatus)
        var cursor = windowStart
        for row in sorted {
            push(state, cursor, row.createdAt)
            state = SegmentState(status: row.status)
            cursor = row.createdAt
        }
        push(state, cursor, now)

        var known: TimeInterval = 0
        var connected: TimeInterval = 0
        for seg in segments {
            let len = seg.end.timeIntervalSince(seg.start)
            if seg.state != .unknown { known += len }
            if seg.state == .online || seg.state == .updating { connected += len }
        }
        let percent: Double? = known > 0 ? (connected / known * 1000).rounded() / 10 : nil
        return StatusHistory(segments: segments, onlinePercent: percent, outages: segments.filter { $0.state == .offline })
    }
}
