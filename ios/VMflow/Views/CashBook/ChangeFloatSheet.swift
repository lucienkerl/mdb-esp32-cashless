import SwiftUI

/// Bucht Wechselgeld, das der Barkasse entnommen und in die Münztuben eines
/// Automaten gelegt wird — oder von dort zurückgeholt wird.
///
/// Der Automatenbezug ist immer Pflicht, unabhängig von `trackPerMachine`:
/// diese Einstellung verankert den Erwartungswert, sagt aber nichts darüber
/// aus, wo das vorgestreckte Geld liegt.
struct ChangeFloatSheet: View {
    let cashBook: CashBook

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    @State private var direction: ChangeFloatDirection = .intoMachine
    @State private var amountText: String = ""
    @State private var selectedMachineId: UUID?
    @State private var description: String = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// Picker source. Deliberately `CashBookMachineRef` (live `vendingMachine`
    /// rows currently assigned to this Barkasse), never `MachineChangeFloat`
    /// rows from `cashBookVM.changeFloat` — a booking can only target a
    /// machine that still exists. This also means the orphaned bucket row
    /// (`machineId == nil`, surfaced by `get_machine_change_float` for a
    /// deleted machine's stranded float) can never appear here as a bookable
    /// target.
    private var assignedMachines: [CashBookMachineRef] {
        cashBookVM.assignedMachines(for: cashBook.id)
    }

    private var currentFloat: Double {
        guard let id = selectedMachineId else { return 0 }
        return cashBookVM.floatBalance(for: id, cashBookId: cashBook.id)
    }

    /// Warnt, wenn mehr zurückgenommen wird als vorgestreckt wurde. Blockiert
    /// nicht — eine Buchung, die die Realität abbildet, wird nie verweigert.
    private var showsNegativeWarning: Bool {
        direction == .backToBox && amount > 0 && amount > currentFloat + 0.001
    }

    private var canSubmit: Bool {
        amount > 0 && selectedMachineId != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("cash_book_change_float_direction", selection: $direction) {
                        Text("cash_book_change_float_into_machine").tag(ChangeFloatDirection.intoMachine)
                        Text("cash_book_change_float_back_to_box").tag(ChangeFloatDirection.backToBox)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } footer: {
                    Text("cash_book_change_float_hint")
                }

                Section("cash_book_for_machine") {
                    if assignedMachines.isEmpty {
                        Text("cash_book_no_assigned_machine_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("cash_book_for_machine", selection: $selectedMachineId) {
                            Text("—").tag(UUID?.none)
                            ForEach(assignedMachines) { m in
                                Text(m.name ?? String(m.id.uuidString.prefix(8)))
                                    .tag(UUID?.some(m.id))
                            }
                        }
                        .labelsHidden()

                        if selectedMachineId != nil {
                            LabeledContent {
                                Text(currentFloat, format: .currency(code: "EUR"))
                                    .monospacedDigit()
                            } label: {
                                Text("cash_book_total_change_float")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("cash_book_amount") {
                    TextField("0,00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.body.monospacedDigit())
                }

                if showsNegativeWarning {
                    Section {
                        Text("cash_book_change_float_negative_warning")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("cash_book_description") {
                    TextField(text: $description) { Text(verbatim: "") }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_change_float")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cash_book_cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        // Set synchronously, before the Task is spawned — the
                        // button's own `.disabled` re-renders immediately, so
                        // a second rapid tap can't race a Task-scheduling
                        // delay into starting a second write to the ledger.
                        isSubmitting = true
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView() } else { Text("cash_book_book_entry") }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
            .task {
                // Bei genau einem zugeordneten Automaten vorauswählen.
                if selectedMachineId == nil, assignedMachines.count == 1 {
                    selectedMachineId = assignedMachines.first?.id
                }
            }
        }
    }

    private func submit() async {
        // `isSubmitting` is already `true` — set synchronously by the button
        // action. This `defer` is what clears it again, on every exit path
        // (including the guard below and a thrown error), so a failed submit
        // never leaves the button permanently disabled.
        defer { isSubmitting = false }
        guard canSubmit, let machineId = selectedMachineId else { return }
        errorMessage = nil
        do {
            try await cashBookVM.recordChangeFloat(
                cashBookId: cashBook.id,
                amount: direction.signedAmount(amount),
                machineId: machineId,
                description: description.trimmingCharacters(in: .whitespaces)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
