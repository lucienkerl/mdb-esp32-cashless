import Foundation

// DeviceConnectivity / FleetConnectivity / StatusHistory — the cases of the
// web's connectivity.test.ts. Run via ./run.sh.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [\(label)] line \(line):\n  got      \(actual)\n  expected \(expected)")
    }
}

let now = Date(timeIntervalSince1970: 1_793_808_000) // 2026-11-04T16:00:00Z
func minAgo(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
func c(_ status: String?, _ at: Date?, since: Date? = nil, mdb: String? = nil) -> DeviceConnectivity {
    DeviceConnectivity.evaluate(status: status, statusAt: at, onlineSince: since, mdbState: mdb, now: now)
}

// ── evaluate ─────────────────────────────────────────────────────────────────

expect(DeviceConnectivity.noDevice.state, .none, "no device")
expect(DeviceConnectivity.noDevice.needsAttention, false, "no device is no problem")
expect(c(nil, nil).state, .never, "never reported")
expect(c("", minAgo(1)).state, .never, "empty status")

let online = c("online", minAgo(2), since: minAgo(600))
expect(online.state, .online, "online")
expect(online.lastContactAt, minAgo(2), "online last contact")
expect(online.since, minAgo(600), "online since")
expect(online.needsAttention, false, "online is fine")

expect(c("online", minAgo(10)).state, .online, "one lost heartbeat")
expect(c("online", minAgo(12)).state, .online, "12 min still online")
let stale = c("online", minAgo(13))
expect(stale.state, .stale, "stale after 12 min")
expect(stale.since, minAgo(13), "stale since last contact")
expect(stale.needsAttention, true, "stale needs attention")
expect(c("online", nil).state, .stale, "online without status_at")

let offline = c("offline", minAgo(120), since: minAgo(9000))
expect(offline.state, .offline, "offline")
expect(offline.since, minAgo(120), "offline since")
expect(offline.onlineSince, minAgo(9000), "offline keeps online since")
expect(offline.needsAttention, true, "offline needs attention")
expect(c("OFFLINE", minAgo(1)).state, .offline, "case-insensitive")

expect(c("ota_updating", minAgo(3)).state, .updating, "fresh update")
expect(c("ota_updating", minAgo(11)).state, .stale, "hanging update")
expect(c("ota_success", minAgo(1)).state, .online, "ota_success is online")
expect(c("ota_failed", minAgo(1)).state, .online, "ota_failed is online")

let ready = c("online", minAgo(1), mdb: "IDLE")
expect(ready.reader, .ready, "reader ready")
expect(ready.needsAttention, false, "ready is fine")
let silent = c("online", minAgo(1), mdb: "INACTIVE")
expect(silent.reader, .inactive, "reader inactive")
expect(silent.needsAttention, true, "inactive needs attention")
expect(c("offline", minAgo(1), mdb: "IDLE").reader, nil, "no reader while offline")

expect(ReaderState(mdbState: "ENABLED"), .ready, "ENABLED")
expect(ReaderState(mdbState: "VEND"), .ready, "VEND")
expect(ReaderState(mdbState: "DISABLED"), .disabled, "DISABLED")
expect(ReaderState(mdbState: "UNKNOWN"), nil, "UNKNOWN")
expect(ReaderState(mdbState: nil), nil, "nil")

// ── fleet ────────────────────────────────────────────────────────────────────

let fleet = FleetConnectivity([
    c("online", minAgo(1)),
    c("online", minAgo(1), mdb: "INACTIVE"),
    c("ota_updating", minAgo(1)),
    c("online", minAgo(47)),
    c("offline", minAgo(120)),
    c(nil, nil),
    .noDevice,
])
expect(fleet.online, 3, "fleet online")
expect(fleet.stale, 1, "fleet stale")
expect(fleet.offline, 1, "fleet offline")
expect(fleet.updating, 1, "fleet updating")
expect(fleet.never, 1, "fleet never")
expect(fleet.none, 1, "fleet none")
expect(fleet.devices, 6, "fleet devices")
expect(fleet.attention, 3, "fleet attention")
expect(fleet.readerInactive, 1, "fleet reader inactive")

// ── rank ─────────────────────────────────────────────────────────────────────

let unordered: [DeviceConnectivity] = [.noDevice, c("online", minAgo(1)), c("offline", minAgo(1)), c("online", minAgo(30)), c("online", minAgo(1), mdb: "INACTIVE")]
let ordered = unordered
    .sorted { $0.rank < $1.rank }
    .map { "\($0.state.rawValue):\($0.reader?.rawValue ?? "")" }
expect(ordered, ["offline:", "stale:", "online:inactive", "online:", "none:"], "rank order")

// ── duration ─────────────────────────────────────────────────────────────────

expect(DurationParts(TimeInterval((3 * 1440 + 4 * 60 + 5) * 60)), DurationParts(days: 3, hours: 4, minutes: 5), "duration parts")
expect(DurationParts(59), DurationParts(days: 0, hours: 0, minutes: 0), "under a minute")
expect(DurationParts(-5), DurationParts(days: 0, hours: 0, minutes: 0), "negative")

// ── history ──────────────────────────────────────────────────────────────────

let H: TimeInterval = 3600
let start = now.addingTimeInterval(-24 * H)
func at(_ h: Double) -> Date { start.addingTimeInterval(h * H) }
func row(_ s: String, _ p: String?, _ h: Double) -> StatusLogRow { StatusLogRow(status: s, prevStatus: p, createdAt: at(h)) }

let quiet = StatusHistory.build(rows: [], currentStatus: "online", windowStart: start, now: now)
expect(quiet.segments, [StatusSegment(state: .online, start: start, end: now)], "no changes")
expect(quiet.onlinePercent, 100, "no changes 100 %")
expect(quiet.outages.count, 0, "no outages")

let busy = StatusHistory.build(rows: [
    row("online", "offline", 12.75),
    row("offline", "online", 12),
    row("ota_updating", "online", 18),
    row("online", "ota_updating", 18.25),
], currentStatus: "online", windowStart: start, now: now)
expect(busy.segments.map(\.state), [.online, .offline, .online, .updating, .online], "segments")
expect(busy.outages, [StatusSegment(state: .offline, start: at(12), end: at(12.75))], "outage")
expect(busy.onlinePercent, 96.9, "percent")

let partial = StatusHistory.build(rows: [
    row("online", nil, 12),
    row("ota_success", "online", 13),
], currentStatus: "ota_success", windowStart: start, now: now)
expect(partial.segments, [
    StatusSegment(state: .unknown, start: start, end: at(12)),
    StatusSegment(state: .online, start: at(12), end: now),
], "merged + unknown")
expect(partial.onlinePercent, 100, "unknown left out")

let outside = StatusHistory.build(rows: [
    StatusLogRow(status: "offline", prevStatus: "online", createdAt: start.addingTimeInterval(-H)),
], currentStatus: "offline", windowStart: start, now: now)
expect(outside.segments, [StatusSegment(state: .offline, start: start, end: now)], "rows outside ignored")
expect(outside.onlinePercent, 0, "0 %")

if failures > 0 {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
print("connectivity: all \(checks) checks passed")
