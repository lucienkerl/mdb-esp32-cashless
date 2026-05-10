import SwiftUI

/// Format hint for an analytics KPI value.
enum KPIFormat {
    case currency
    case number
    case percent
}

/// Single KPI cell rendered inside `AnalyticsKPIGroup`.
struct AnalyticsKPI: Identifiable {
    let id = UUID()
    let label: String
    let value: Double
    let deltaPct: Double?
    let format: KPIFormat
    let icon: String
    let color: Color

    init(
        label: String,
        value: Double,
        deltaPct: Double? = nil,
        format: KPIFormat,
        icon: String = "chart.bar.fill",
        color: Color = .blue
    ) {
        self.label = label
        self.value = value
        self.deltaPct = deltaPct
        self.format = format
        self.icon = icon
        self.color = color
    }
}

/// Adaptive grid of KPI cards. 2 columns on compact width classes, up to 4 on regular.
struct AnalyticsKPIGroup: View {
    let kpis: [AnalyticsKPI]

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        let count = (sizeClass == .regular) ? min(4, kpis.count) : 2
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, count))
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(kpis) { k in
                KPICard(
                    icon: k.icon,
                    title: LocalizedStringKey(k.label),
                    value: format(k.value, k.format),
                    subtitle: k.deltaPct.map { LocalizedStringKey(formatDelta($0)) },
                    color: k.color
                )
            }
        }
        .padding(.horizontal)
    }

    private func format(_ v: Double, _ f: KPIFormat) -> String {
        switch f {
        case .currency:
            return v.formatted(.currency(code: "EUR"))
        case .number:
            return Int(v).formatted(.number)
        case .percent:
            return String(format: "%.1f%%", v)
        }
    }

    private func formatDelta(_ d: Double) -> String {
        let sign = d >= 0 ? "+" : ""
        return String(format: "\(sign)%.1f%%", d)
    }
}

#Preview {
    AnalyticsKPIGroup(kpis: [
        AnalyticsKPI(label: "Revenue", value: 1280.50, deltaPct: 12.4, format: .currency, icon: "eurosign.circle.fill", color: .blue),
        AnalyticsKPI(label: "Sales", value: 327, deltaPct: -3.1, format: .number, icon: "cart.fill", color: .green),
        AnalyticsKPI(label: "Conversion", value: 4.7, deltaPct: 1.2, format: .percent, icon: "person.fill", color: .orange),
        AnalyticsKPI(label: "Stockouts", value: 5, deltaPct: nil, format: .number, icon: "exclamationmark.triangle.fill", color: .red)
    ])
    .padding()
}
