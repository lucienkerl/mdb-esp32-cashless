import SwiftUI

/// Words and colours for `DeviceNetwork` — iOS counterpart of the web's
/// `NetworkBadge.vue` / `SignalIcon.vue`.
enum NetworkText {
    static func kind(_ kind: DeviceNetwork.Kind) -> String {
        switch kind {
        case .wifi: return String(localized: "WiFi")
        case .cellular: return String(localized: "Cellular")
        }
    }

    static func quality(_ quality: DeviceNetwork.Quality) -> String {
        switch quality {
        case .excellent: return String(localized: "Excellent")
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .weak: return String(localized: "Weak")
        case .none: return String(localized: "Barely any signal")
        }
    }

    static func color(_ tone: DeviceNetwork.Tone?, muted: Bool = false) -> Color {
        if muted { return .secondary }
        switch tone {
        case .ok: return .green
        case .weak: return .orange
        case .bad: return .red
        case nil: return .secondary
        }
    }

    static func isWeak(_ n: DeviceNetwork) -> Bool { n.tone == .weak || n.tone == .bad }
}

/// WiFi fan (dot + 3 arcs) or cellular bars, with 0–4 filled steps.
struct SignalIcon: View {
    let kind: DeviceNetwork.Kind
    let level: Int?
    let tone: DeviceNetwork.Tone?
    var muted = false
    var size: CGFloat = 14
    /// Overrides the tone colour (e.g. white on a coloured tile).
    var tint: Color? = nil

    private var color: Color { tint ?? NetworkText.color(tone, muted: muted) }
    private func on(_ step: Int) -> Bool {
        guard let level else { return false }
        return kind == .wifi && step == 1 ? true : level >= step
    }

    var body: some View {
        Group {
            if kind == .wifi { wifi } else { bars }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var wifi: some View {
        Canvas { ctx, box in
            let s = box.width / 16
            let lw = 1.9 * s
            // Arcs around the dot at (8, 13), radii 4 / 7.2 / 10.2, ±45°.
            for (step, r) in [(2, 4.0), (3, 7.2), (4, 10.2)] {
                let d = r * 0.7071
                var p = Path()
                p.move(to: CGPoint(x: (8 - d) * s, y: (13 - d) * s))
                p.addQuadCurve(to: CGPoint(x: (8 + d) * s, y: (13 - d) * s),
                               control: CGPoint(x: 8 * s, y: (13 - r * 1.4142) * s))
                ctx.stroke(p, with: .color(color.opacity(on(step) ? 1 : 0.25)),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            let dot = Path(ellipseIn: CGRect(x: (8 - 1.7) * s, y: (13 - 1.7) * s, width: 3.4 * s, height: 3.4 * s))
            ctx.fill(dot, with: .color(color.opacity(on(1) ? 1 : 0.25)))
        }
    }

    private var bars: some View {
        HStack(alignment: .bottom, spacing: max(1, size / 12)) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color.opacity(on(i) ? 1 : 0.25))
                    .frame(width: max(2, size / 6), height: size * 0.85 * CGFloat(i) / 4)
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
    }
}

/// Compact "[icon] Office-WiFi" for the line under the status badge. Weak
/// signal names the problem instead of the SSID; offline shows the last known
/// network greyed out.
struct NetworkInline: View {
    let network: DeviceNetwork
    var offline = false

    var body: some View {
        let weak = !offline && NetworkText.isWeak(network)
        HStack(spacing: 4) {
            SignalIcon(kind: network.kind, level: network.level, tone: network.tone, muted: offline, size: 12)
            Text(label(weak: weak))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(weak ? .caption.weight(.semibold) : .caption)
        .foregroundStyle(offline ? Color.secondary : weak ? NetworkText.color(network.tone) : Color.secondary)
        .accessibilityElement(children: .combine)
    }

    private func label(weak: Bool) -> String {
        let kind = NetworkText.kind(network.kind)
        let name = network.name ?? kind
        if offline { return String(localized: "last \(name)") }
        if weak, let q = network.quality { return "\(kind) · \(NetworkText.quality(q))" }
        if network.kind == .cellular, let mode = network.mode { return "\(name) · \(mode)" }
        return name
    }
}
