import SwiftUI

/// Three-station vertical flow: In Automaten → In der Kasse → Letzte Bankeinzahlung.
/// Used on both the full Cash Book screen and the dashboard tile (with `compact = true`).
struct FlowVisualisationCard: View {
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
