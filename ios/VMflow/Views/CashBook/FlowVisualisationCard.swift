import SwiftUI

/// Three-station vertical flow: In Automaten → In der Kasse → Letzte Bankeinzahlung.
/// Used on both the full Cash Book screen and the dashboard tile (with `compact = true`).
struct FlowVisualisationCard: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    let theoreticalCash: TheoreticalCash?
    let currentBalance: Double
    let lastBankDeposit: CashBookEntry?
    let bankDepositThreshold: Double
    /// When true, render the three station rows but suppress the action buttons.
    let compact: Bool
    let onWithdraw: (() -> Void)?
    let onDeposit: (() -> Void)?

    init(
        theoreticalCash: TheoreticalCash?,
        currentBalance: Double,
        lastBankDeposit: CashBookEntry?,
        bankDepositThreshold: Double,
        compact: Bool = false,
        onWithdraw: (() -> Void)? = nil,
        onDeposit: (() -> Void)? = nil
    ) {
        self.theoreticalCash = theoreticalCash
        self.currentBalance = currentBalance
        self.lastBankDeposit = lastBankDeposit
        self.bankDepositThreshold = bankDepositThreshold
        self.compact = compact
        self.onWithdraw = onWithdraw
        self.onDeposit = onDeposit
    }

    private var withdrawalNeeded: Bool {
        (theoreticalCash?.cashSalesSince ?? 0) > 0.001
    }

    private var depositRecommended: Bool {
        currentBalance >= bankDepositThreshold
    }

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            stationRow(
                icon: "storefront.fill",
                title: "cash_book_in_machines",
                amount: theoreticalCash?.cashSalesSince ?? 0,
                subtitle: machineBreakdownSubtitle
            )

            if !compact {
                arrowAndButton(
                    isPrimary: true,
                    label: "cash_book_record_withdrawal",
                    pulse: withdrawalNeeded,
                    action: onWithdraw
                )
            } else {
                arrow()
            }

            stationRow(
                icon: "tray.fill",
                title: "cash_book_in_box",
                amount: currentBalance,
                subtitle: lastEntrySubtitle
            )

            if !compact {
                arrowAndButton(
                    isPrimary: false,
                    label: "cash_book_record_payout",
                    pulse: depositRecommended,
                    action: onDeposit
                )
            } else {
                arrow()
            }

            stationRow(
                icon: "building.columns.fill",
                title: "cash_book_last_bank_deposit",
                amount: lastBankDeposit.map { abs($0.amount) },
                subtitle: lastDepositSubtitle
            )

            // Wechselgeld ist eine Seitentasche der Kasse, kein Kettenglied.
            changeFloatSection
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func stationRow(icon: String, title: LocalizedStringKey, amount: Double?, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                if let s = subtitle {
                    Text(s).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Group {
                if let amount {
                    Text(amount, format: .currency(code: "EUR"))
                        .monospacedDigit()
                        .font(.title3.weight(.semibold))
                } else {
                    Text("cash_book_no_deposit_yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private func arrow() -> some View {
        Image(systemName: "arrow.down")
            .foregroundStyle(.tertiary)
            .font(.callout)
    }

    @ViewBuilder
    private func arrowAndButton(
        isPrimary: Bool,
        label: LocalizedStringKey,
        pulse: Bool,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 6) {
            arrow()
            Button(action: { action?() }) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(isPrimary ? .green : .accentColor)
            .controlSize(.regular)
            .overlay(alignment: .center) {
                if pulse {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.orange.opacity(0.6), lineWidth: 2)
                        .padding(-2)
                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulse)
                }
            }
            arrow()
        }
        .disabled(action == nil)
    }

    @ViewBuilder
    private var changeFloatSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("cash_book_change_float_station", systemImage: "circle.grid.2x2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // No total while the balance couldn't be loaded — showing 0
                // there would read as "nothing advanced", which is a
                // different, stronger claim than "we don't know".
                if !cashBookVM.changeFloatUnavailable {
                    Text(cashBookVM.changeFloat.reduce(0) { $0 + $1.floatBalance },
                         format: .currency(code: "EUR"))
                        .font(.headline.monospacedDigit())
                }
            }

            if cashBookVM.changeFloatUnavailable {
                Label("cash_book_change_float_unavailable", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if cashBookVM.changeFloat.isEmpty {
                Text("cash_book_change_float_empty")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(changeFloatByMachine) { row in
                    HStack {
                        Text(row.name)
                        Spacer()
                        Text(row.balance, format: .currency(code: "EUR"))
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 8)
    }

    /// One row per machine, summed across cash books — `MachineChangeFloat.id`
    /// is per (machine, cash book) row, so a machine that moved between cash
    /// books would otherwise show up twice and can't key a `ForEach` safely.
    /// Keyed on `machineId` rather than `machineName`, which has no
    /// uniqueness constraint and could misattribute a balance on re-sort.
    private struct MachineFloatRow: Identifiable {
        let id: UUID
        let name: String
        let balance: Double
    }

    private var changeFloatByMachine: [MachineFloatRow] {
        var byId: [UUID: (name: String, balance: Double)] = [:]
        for row in cashBookVM.changeFloat {
            var existing = byId[row.machineId] ?? (name: row.machineName ?? "—", balance: 0)
            existing.balance += row.floatBalance
            byId[row.machineId] = existing
        }
        return byId
            .map { MachineFloatRow(id: $0.key, name: $0.value.name, balance: $0.value.balance) }
            .sorted { $0.balance > $1.balance }
    }

    // MARK: - Subtitle composition

    private var machineBreakdownSubtitle: String? {
        guard let machines = theoreticalCash?.machines, !machines.isEmpty else { return nil }
        let lines = machines.map { m in
            let formatted = NumberFormatter.localizedString(from: m.cashSales as NSNumber, number: .currency)
            return "\(m.machineName ?? "—") +\(formatted)"
        }
        return lines.joined(separator: " · ")
    }

    private var lastEntrySubtitle: String? {
        guard let date = theoreticalCash?.lastEntryAt else { return nil }
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        let dateString = f.string(from: date)
        return String(format: NSLocalizedString("cash_book_since_date", comment: ""), dateString)
    }

    private var lastDepositSubtitle: String? {
        guard let entry = lastBankDeposit else { return nil }
        let days = Calendar.current.dateComponents([.day], from: entry.createdAt, to: Date()).day ?? 0
        if days == 0 {
            return NSLocalizedString("cash_book_today", comment: "")
        }
        return String(format: NSLocalizedString("cash_book_ago_days", comment: ""), days)
    }
}
