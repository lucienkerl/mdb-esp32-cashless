import SwiftUI

/// Small delta pill: green up-arrow for positive, red down-arrow for negative.
/// Renders nothing when `deltaPct` is `nil`.
struct ComparePeriodBadge: View {
    let deltaPct: Double?

    var body: some View {
        if let d = deltaPct {
            let isUp = d >= 0
            HStack(spacing: 2) {
                Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                    .font(.caption2)
                Text(formatted(d))
                    .font(.caption2.bold())
                    .monospacedDigit()
            }
            .foregroundStyle(isUp ? Color.green : Color.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isUp ? Color.green : Color.red).opacity(0.12))
            .clipShape(Capsule())
        } else {
            EmptyView()
        }
    }

    private func formatted(_ d: Double) -> String {
        let sign = d >= 0 ? "+" : ""
        return String(format: "\(sign)%.1f%%", d)
    }
}

#Preview {
    VStack(spacing: 8) {
        ComparePeriodBadge(deltaPct: 12.4)
        ComparePeriodBadge(deltaPct: -3.1)
        ComparePeriodBadge(deltaPct: 0)
        ComparePeriodBadge(deltaPct: nil)
    }
    .padding()
}
