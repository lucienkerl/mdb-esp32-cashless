import SwiftUI

// MARK: - Labels

/// Localized words, colours and time labels for `DeviceConnectivity` — the
/// iOS counterpart of the web's `useConnectivity()`.
enum ConnectivityText {
    static func state(_ c: DeviceConnectivity) -> String {
        switch c.state {
        case .online: return String(localized: "Online")
        case .stale: return String(localized: "No response")
        case .offline: return String(localized: "Offline")
        case .updating: return String(localized: "Updating")
        case .never: return String(localized: "Never connected")
        case .none: return String(localized: "No device")
        }
    }

    /// The one line under a status: "Contact 2 min ago", "Offline since Mon 14:32 · 2 hr ago", …
    static func time(_ c: DeviceConnectivity, now: Date = Date()) -> String {
        switch c.state {
        case .online:
            return String(localized: "Contact \(ago(c.lastContactAt, now: now))")
        case .stale:
            return String(localized: "Last contact \(ago(c.lastContactAt, now: now))")
        case .offline:
            guard let since = c.since else { return state(c) }
            return String(localized: "Offline since \(clock(since, now: now)) · \(ago(since, now: now))")
        case .updating:
            return String(localized: "Update started \(ago(c.since, now: now))")
        case .never:
            return String(localized: "Has never reported in")
        case .none:
            return String(localized: "No device assigned")
        }
    }

    static func reader(_ r: ReaderState) -> String {
        switch r {
        case .ready: return String(localized: "Reader ready")
        case .disabled: return String(localized: "Reader disabled")
        case .inactive: return String(localized: "Machine not responding")
        }
    }

    static func readerHint(_ r: ReaderState) -> String {
        switch r {
        case .ready: return String(localized: "The machine is polling the reader, cashless payment works.")
        case .disabled: return String(localized: "The machine has disabled cashless payment for now, e.g. because it is out of service.")
        case .inactive: return String(localized: "The device is online, but the machine is not polling the reader. Cashless payment is not possible.")
        }
    }

    static func color(_ state: ConnectivityState) -> Color {
        switch state {
        case .online: return .green
        case .stale: return .orange
        case .offline: return .red
        case .updating: return .purple
        case .never, .none: return .gray
        }
    }

    /// Colour of the time line: only a problem carries colour.
    static func timeColor(_ state: ConnectivityState) -> Color {
        switch state {
        case .offline: return .red
        case .stale: return .orange
        default: return .secondary
        }
    }

    static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        if now.timeIntervalSince(date) < 60 { return String(localized: "just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "14:32" today, "Mon 14:32" within the last six days, "12.10. 14:32" before that.
    static func clock(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        let startOfToday = cal.startOfDay(for: now)
        if date >= startOfToday { return time }
        if let sixDaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday), date >= sixDaysAgo {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.twoDigits))) \(time)"
    }

    /// "3d 4h", "2h 5m", "12m" in the user's language.
    static func duration(_ interval: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.allowedUnits = interval >= 86400 ? [.day, .hour] : [.hour, .minute]
        return f.string(from: max(60, interval)) ?? "—"
    }
}

// MARK: - Badge

/// Dot + word for a device's connectivity — never colour alone.
struct StatusBadge: View {
    let connectivity: DeviceConnectivity

    var body: some View {
        let color = ConnectivityText.color(connectivity.state)
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(ConnectivityText.state(connectivity))
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// Badge plus the time line, re-evaluated every 30 s so "contact 2 min ago"
/// and the online → no response switch move on by themselves.
struct ConnectivityStatusView: View {
    let machine: VendingMachine
    var showsReader = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let c = machine.connectivity(now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                StatusBadge(connectivity: c)
                Text(ConnectivityText.time(c, now: context.date))
                    .font(.caption)
                    .foregroundStyle(ConnectivityText.timeColor(c.state))
                    .lineLimit(1)
                if showsReader, c.reader == .inactive {
                    Text(ConnectivityText.reader(.inactive))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
                }
            }
        }
    }
}

/// What the state means and what to check — only for a device that is not simply online.
struct ConnectivityNotice: View {
    let connectivity: DeviceConnectivity

    var body: some View {
        if let text = explanation(for: connectivity) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let check = text.check {
                    Text(check)
                        .font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func explanation(for c: DeviceConnectivity) -> (body: String, check: String?)? {
        switch c.state {
        case .offline:
            let at = c.since.map { ConnectivityText.clock($0) } ?? "—"
            return (
                String(localized: "The server noticed the connection drop at \(at). The device sends sales from this period once it is back online."),
                String(localized: "Check: power at the machine, network at the site, the status LED on the device (blinking yellow = looking for a network).")
            )
        case .stale:
            return (
                String(localized: "The device has not signed off, but it has sent no heartbeat for more than 12 minutes (normally every 5 min). Usually a network problem at the site, less often a problem on the server."),
                String(localized: "Check: is data still arriving from other machines? If not, it is the server; otherwise treat it like \"Offline\".")
            )
        case .updating:
            return (String(localized: "The new firmware is being installed. The device restarts afterwards and is briefly offline. If it takes longer than 10 minutes, this turns into \"No response\"."), nil)
        case .online where c.reader == .inactive:
            return (ConnectivityText.readerHint(.inactive), nil)
        default:
            return nil
        }
    }
}

// MARK: - 24 h bar

/// The connection history of the last 24 hours as one bar.
struct ConnectionHistoryBar: View {
    let history: StatusHistory

    var body: some View {
        GeometryReader { geo in
            let total = history.segments.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            HStack(spacing: 1) {
                ForEach(Array(history.segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(Self.color(seg.state))
                        .frame(width: total > 0 ? max(2, geo.size.width * seg.end.timeIntervalSince(seg.start) / total) : 0)
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement()
        .accessibilityLabel(Text(Self.percentLabel(history)))
    }

    static func color(_ state: SegmentState) -> Color {
        switch state {
        case .online: return .green
        case .offline: return .red
        case .updating: return .purple
        case .unknown: return Color.gray.opacity(0.25)
        }
    }

    static func percentLabel(_ history: StatusHistory) -> String {
        guard let pct = history.onlinePercent else { return String(localized: "No data yet") }
        // Never round a real outage up to "100 %".
        let shown = pct < 100 ? min(Int(pct.rounded(.down)), 99) : 100
        return String(localized: "\(shown)% online")
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusBadge(connectivity: DeviceConnectivity.evaluate(status: "online", statusAt: Date(), onlineSince: nil, mdbState: "IDLE"))
        StatusBadge(connectivity: DeviceConnectivity.evaluate(status: "online", statusAt: Date().addingTimeInterval(-3000), onlineSince: nil, mdbState: nil))
        StatusBadge(connectivity: DeviceConnectivity.evaluate(status: "offline", statusAt: Date().addingTimeInterval(-7200), onlineSince: nil, mdbState: nil))
        StatusBadge(connectivity: .noDevice)
    }
}
