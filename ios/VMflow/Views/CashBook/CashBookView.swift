import SwiftUI

struct CashBookView: View {
    @EnvironmentObject var cashBookVM: CashBookViewModel
    @State private var showWithdrawal = false
    @State private var showDeposit = false
    @State private var showExpense = false
    @State private var showChangeFloat = false

    var body: some View {
        Group {
            if cashBookVM.cashBooks.isEmpty {
                emptyState
            } else if let book = cashBookVM.selectedCashBook {
                content(book: book)
            } else {
                pickerState
            }
        }
        .navigationTitle("cash_book_title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Picker only if there are multiple cash books — otherwise hidden.
            if cashBookVM.cashBooks.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    cashBookSwitcher
                }
            }
            if cashBookVM.selectedCashBook != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showExpense = true
                        } label: {
                            Label("cash_book_record_expense", systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            showChangeFloat = true
                        } label: {
                            Label("cash_book_record_change_float", systemImage: "circle.grid.2x2")
                        }
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .accessibilityLabel("cash_book_more_actions")
                }
            }
        }
        .dataRefreshable {
            await cashBookVM.refresh()
        }
        .task {
            // Refresh theoretical cash on every screen open
            if let id = cashBookVM.selectedCashBookId {
                await cashBookVM.loadTheoreticalCash(for: id)
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func content(book: CashBook) -> some View {
        List {
            Section {
                FlowVisualisationCard(
                    theoreticalCash: cashBookVM.theoreticalCash,
                    currentBalance: cashBookVM.currentBalance,
                    lastBankDeposit: cashBookVM.lastBankDeposit,
                    bankDepositThreshold: book.bankDepositThreshold,
                    cashBookId: book.id,
                    onWithdraw: { showWithdrawal = true },
                    onDeposit: { showDeposit = true }
                )
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
            }

            Section("cash_book_title") {
                EntriesListSection(
                    entries: cashBookVM.entries,
                    machineName: { cashBookVM.machineName($0) }
                )
            }
        }
        .sheet(isPresented: $showWithdrawal) {
            WithdrawalSheet(cashBook: book, fromTour: false)
                .environmentObject(cashBookVM)
        }
        .sheet(isPresented: $showDeposit) {
            BankDepositSheet(cashBook: book)
                .environmentObject(cashBookVM)
        }
        .sheet(isPresented: $showExpense) {
            ExpenseSheet(cashBook: book)
                .environmentObject(cashBookVM)
        }
        .sheet(isPresented: $showChangeFloat) {
            ChangeFloatSheet(cashBook: book)
                .environmentObject(cashBookVM)
        }
    }

    /// Toolbar Menu showing the current Barkasse name + chevron, with a
    /// checkmark next to the selected entry. Tapping a different one
    /// triggers a full reload of entries + theoretical cash via
    /// `cashBookVM.selectCashBook(_:)`.
    private var cashBookSwitcher: some View {
        Menu {
            ForEach(cashBookVM.cashBooks) { cb in
                Button {
                    Task { await cashBookVM.selectCashBook(cb.id) }
                } label: {
                    HStack {
                        Text(cb.name)
                        if cb.id == cashBookVM.selectedCashBookId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(cashBookVM.selectedCashBook?.name ?? "—")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "banknote")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("cash_book_no_barkasse_yet")
                .font(.headline)
            Text("cash_book_setup_in_web")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var pickerState: some View {
        // ≥2 Barkassen, no selection — let the user pick.
        VStack(spacing: 16) {
            Text("cash_book_title").font(.headline)
            ForEach(cashBookVM.cashBooks) { cb in
                Button(cb.name) {
                    Task { await cashBookVM.selectCashBook(cb.id) }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
