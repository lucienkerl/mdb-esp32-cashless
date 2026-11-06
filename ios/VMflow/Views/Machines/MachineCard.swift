import SwiftUI

/// Card component for the machine list showing key stats at a glance.
struct MachineCard: View {
    let stats: MachineStats
    @State private var deficitsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Name + Status
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.machine.displayName)
                        .font(.headline)
                        .lineLimit(1)

                    ConnectivityStatusView(machine: stats.machine)
                }

                Spacer()

                StockHealthIndicator(health: stats.stockHealth)
            }

            Divider()

            // Sales Stats Grid (2×2)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 8) {
                salesStatCell(
                    label: "Today",
                    revenue: stats.todayRevenue,
                    count: stats.todaySalesCount
                )
                salesStatCell(
                    label: "Yesterday",
                    revenue: stats.yesterdayRevenue,
                    count: stats.yesterdaySalesCount
                )
                salesStatCell(
                    label: "This Week",
                    revenue: stats.thisWeekRevenue,
                    count: stats.thisWeekSalesCount
                )
                salesStatCell(
                    label: "Last Week",
                    revenue: stats.lastWeekRevenue,
                    count: stats.lastWeekSalesCount
                )
            }

            // Summary badges — same set and order as the PWA machine card
            // (`machines.outOfStock`, `refillNeeded`, `swapNeeded`,
            // `noWarehouseStock`, `topoffRecommended`, `emptySlotsWithStock`).
            if stats.emptyTrays > 0 || stats.lowTrays > 0 || stats.swapNeededCount > 0
                || stats.noStockCount > 0 || stats.fillTrays > 0 || stats.emptySlotsWithStock > 0 {
                FlowLayout(spacing: 6) {
                    if stats.emptyTrays > 0 {
                        summaryBadge("\(stats.emptyTrays) out of stock", bg: .red.opacity(0.1), fg: .red)
                    }
                    if stats.lowTrays > 0 {
                        summaryBadge("\(stats.lowTrays) refill needed", bg: .orange.opacity(0.1), fg: .orange)
                    }
                    if stats.swapNeededCount > 0 {
                        summaryBadge("\(stats.swapNeededCount) swap product", bg: .orange.opacity(0.1), fg: .orange)
                    }
                    if stats.noStockCount > 0 {
                        summaryBadge("\(stats.noStockCount) no stock", bg: Color(.systemGray5), fg: .secondary)
                    }
                    if stats.fillTrays > 0 {
                        summaryBadge("\(stats.fillTrays) recommended to top off", bg: .blue.opacity(0.1), fg: .blue)
                    }
                    // Hint only: a slot is empty but its product is still
                    // stocked in another slot — never counts as out of stock.
                    if stats.emptySlotsWithStock > 0 {
                        summaryBadge("\(stats.emptySlotsWithStock) slots empty, product in another slot", bg: Color(.systemGray5), fg: .secondary)
                    }
                }
            }

            // Product Deficit Rows
            if !stats.trayDeficits.isEmpty {
                let visible = deficitsExpanded
                    ? stats.trayDeficits
                    : Array(stats.trayDeficits.prefix(4))
                let remaining = stats.trayDeficits.count - 4

                VStack(spacing: 4) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { _, deficit in
                        deficitRow(deficit)
                    }
                    if remaining > 0 {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                deficitsExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(deficitsExpanded ? "Show less" : "+\(remaining) more")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: deficitsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Stock Bar
            if stats.totalTrays > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(stockPercentValue)%")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    StockBar(
                        current: stockPercentValue,
                        capacity: 100,
                        showLabel: false,
                        height: 6
                    )
                }
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .hoverEffect(.highlight)
    }

    /// Rounded like the PWA (`Math.round`), not truncated.
    private var stockPercentValue: Int {
        Int((stats.stockPercent * 100).rounded())
    }

    private func salesStatCell(label: LocalizedStringKey, revenue: Double, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(formatEUR(revenue))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text("\(count) sales")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.fill.tertiary))
    }

    private func summaryBadge(_ text: LocalizedStringKey, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    /// Row-based deficit display matching the web frontend's product list.
    private func deficitRow(_ deficit: TrayDeficit) -> some View {
        let isSwap = deficit.warehouseAvailability == .needsSwap
        let isNoStock = deficit.warehouseAvailability == .noStock
        let isDimmed = isNoStock

        // Text color based on warehouse availability + severity
        let textColor: Color = {
            if isSwap { return .orange }
            if isNoStock { return .secondary }
            switch deficit.severity {
            case .critical: return .red
            case .low: return .orange
            case .fillBelow: return .blue
            }
        }()

        return HStack(spacing: 6) {
            ProductImage(imagePath: deficit.imagePath, size: 20)

            HStack(spacing: 4) {
                Text(deficit.productName)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Text("(-\(deficit.deficit))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(textColor)

            if deficit.isDiscontinued {
                Text("DC")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color(.systemGray5)))
            }

            Spacer(minLength: 0)

            // Warehouse availability label (matches web: "In Stock", "Swap", "No Stock")
            switch deficit.warehouseAvailability {
            case .inStock:
                Text("In Stock")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
            case .needsSwap:
                Text("Swap")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            case .noStock:
                Text("No Stock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            case .unknown:
                EmptyView()
            }
        }
        .opacity(isDimmed ? 0.5 : 1.0)
    }

    private func formatEUR(_ amount: Double) -> String {
        String(format: "%.2f\u{00A0}\u{20AC}", amount)
    }
}

// MARK: - Flow Layout

/// Simple horizontal wrapping layout for deficit pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var positions: [CGPoint]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                // Wrap to next row
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            totalHeight = y + rowHeight
        }

        return ArrangeResult(
            size: CGSize(width: totalWidth, height: totalHeight),
            positions: positions
        )
    }
}

#Preview {
    let machine = VendingMachine(
        id: UUID(),
        name: "Office Kitchen",
        locationLat: nil,
        locationLon: nil,
        embedded: nil,
        countryCode: "DE",
        embeddeds: Embedded(
            id: UUID(),
            status: "online",
            statusAt: Date(),
            subdomain: 1,
            macAddress: nil,
            firmwareVersion: "1.0.0"
        )
    )

    var stats = MachineStats(machine: machine)
    stats.todayRevenue = 42.50
    stats.todaySalesCount = 15
    stats.yesterdayRevenue = 38.00
    stats.yesterdaySalesCount = 12
    stats.thisWeekRevenue = 185.50
    stats.thisWeekSalesCount = 62
    stats.lastWeekRevenue = 210.00
    stats.lastWeekSalesCount = 71
    stats.totalTrays = 8
    stats.lowTrays = 2
    stats.stockPercent = 0.65

    return MachineCard(stats: stats)
        .padding()
}
