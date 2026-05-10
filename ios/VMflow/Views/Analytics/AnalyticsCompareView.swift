// ios/VMflow/Views/Analytics/AnalyticsCompareView.swift
import SwiftUI

/// Compare modal for 2–4 selected machines.
/// - iPad (regular size class): up to 4 cards side-by-side via HStack.
/// - iPhone (compact): vertically stacked cards (stepwise selection happens
///   in AnalyticsMachinesView's checkbox picker — this sheet only renders the
///   diff once 2+ machines are picked).
///
/// TODO Phase 6b: add iPad MapKit bubble map showing the selected machines
/// alongside the comparison cards.
struct AnalyticsCompareView: View {
    let machines: [AnalyticsMachinesData.MachineRow]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        NavigationStack {
            ScrollView {
                if sizeClass == .regular {
                    // iPad: HStack of up to 4 cards side-by-side
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(machines) { m in
                            compareCard(m: m).frame(maxWidth: .infinity)
                        }
                    }
                    .padding()
                } else {
                    // iPhone: stacked cards
                    LazyVStack(spacing: 12) {
                        ForEach(machines) { m in
                            compareCard(m: m)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Compare (\(machines.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private func compareCard(m: AnalyticsMachinesData.MachineRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(m.currentOnline ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(m.name).font(.headline).lineLimit(1)
                Spacer()
            }
            Divider()
            compareRow(label: "Revenue", value: m.revenue.formatted(.currency(code: "EUR")))
            compareRow(label: "Units", value: String(m.units))
            compareRow(
                label: "Conversion",
                value: m.conversionPct.map { String(format: "%.1f%%", $0) } ?? "—"
            )
            if let gap = m.lastSaleGapMinutes {
                compareRow(label: "Last sale", value: formatGap(gap))
            } else {
                compareRow(label: "Last sale", value: "—")
            }
            if let status = m.status, !status.isEmpty {
                compareRow(label: "Status", value: status.capitalized)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func compareRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline).monospacedDigit()
        }
    }

    private func formatGap(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}
