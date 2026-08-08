import SwiftUI

struct WithdrawalSheet: View {
    let cashBook: CashBook
    /// Currently used only for analytics/future-proofing; description text is
    /// the same regardless of origin (matches web default exactly).
    let fromTour: Bool
    /// When opened from a refill tour, the machine IDs the operator actually
    /// visited. Scopes the expected-cash figure and the per-machine breakdown
    /// to just those machines, so a partial tour doesn't imply every machine
    /// on the Barkasse was emptied. `nil` (the default, used by the manual
    /// cash-book withdrawal) keeps the whole-Barkasse figure. Only IDs that
    /// belong to this Barkasse have any effect — the rest are filtered out by
    /// the theoretical breakdown, which already contains only its machines.
    var tourMachineIds: Set<UUID>? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var cashBookVM: CashBookViewModel

    /// Raw text for the counted-amount field — supports expressions like
    /// "10+15.50", "20*3", "100/2". Mirrors the WarehouseView pattern.
    @State private var countedText: String = ""
    @State private var floatBackText: String = ""
    /// Per-machine Rücklage-Beträge im Mehrfach-Modus (`isMultiMachine`),
    /// als Rohtext keyed by machine id — ein Eintrag pro Zeile in
    /// `multiFloatSection`. Ungenutzt im Einzel- und manuellen Fall.
    @State private var multiFloatTexts: [UUID: String] = [:]
    @FocusState private var countedFieldFocused: Bool
    @State private var description: String = NSLocalizedString("cash_book_default_withdrawal_desc", comment: "")
    @State private var selectedMachineId: UUID?
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Sheet-local copy of TheoreticalCash for the *passed-in* `cashBook`.
    /// Avoids relying on `cashBookVM.theoreticalCash` which may be stale
    /// or for a different Barkasse (multi-Barkasse refill case).
    @State private var theoretical: TheoreticalCash?

    /// Evaluated counted value (0 when text is empty or invalid).
    private var counted: Double {
        evaluateExpression(countedText) ?? 0
    }

    /// Expected cash, scoped to the visited machines when opened from a tour
    /// (see `tourMachineIds`). Falls back to the whole-Barkasse figure for a
    /// manual withdrawal.
    private var expected: Double {
        theoretical?.expectedCash(forMachines: tourMachineIds) ?? 0
    }

    /// Per-machine breakdown rows, scoped to match `expected`.
    private var breakdownMachines: [TheoreticalCash.PerMachineCashSales] {
        theoretical?.machineBreakdown(forMachines: tourMachineIds) ?? []
    }

    private var difference: Double {
        counted - expected
    }

    /// Mehrfach-Erfassung greift, wenn die Tour mehr als einen Automaten
    /// besucht hat — dann zwingt ein einzelnes Rücklage-Feld den gesamten
    /// Betrag auf einen Automaten, obwohl er tatsächlich auf mehrere verteilt
    /// wurde. Bei genau einem besuchten Automaten (`tourMachineIds` mit
    /// einem Element oder `nil`, d.h. eine manuelle Entnahme) bleibt das
    /// Sheet unverändert beim bisherigen Einzel-Feld.
    private var isMultiMachine: Bool {
        (tourMachineIds?.count ?? 0) > 1
    }

    /// Machines to report via the new `p_emptied_machine_ids` RPC parameter
    /// (20260807000900), scoped to *this* Barkasse via `breakdownMachines`.
    /// Non-empty only when the tour visited more than one machine of this
    /// Barkasse — a single visited machine (or a manual withdrawal, where
    /// `breakdownMachines` mirrors the whole-Barkasse list but the picker
    /// still drives attribution) keeps today's `machineId` representation
    /// unchanged. When non-empty, the withdrawal's `machineId` must be sent
    /// as `nil` — the RPC rejects a non-null `p_machine_id` together with a
    /// non-empty list.
    private var emptiedMachineIds: [UUID] {
        guard tourMachineIds != nil, breakdownMachines.count > 1 else { return [] }
        return breakdownMachines.map(\.machineId)
    }

    /// Rücklage in die Münztuben (nicht-negativ; die RPC negiert intern).
    /// Whitespace wird getrimmt, bevor geparst wird: `Double.init?` lehnt
    /// " 50 " ab, und ohne das Trimmen würde eine eingefügte Zahl mit
    /// Leerzeichen stillschweigend als 0 gebucht — die Entnahme liefe dann
    /// über den vollen Betrag durch, ohne dass die Rücklage im Kassenbuch
    /// auftaucht. Gleiches Verhalten wie `evaluateExpression` beim
    /// gezählten Betrag.
    private var floatBack: Double {
        parseAmount(floatBackText)
    }

    /// Whether the single-machine Rücklage field parses cleanly. `false`
    /// only when the field is non-empty AND unparseable (e.g. "1.234,50",
    /// a thousands-separator format `parseAmount` doesn't accept) — an empty
    /// field is valid and means "no Rücklage". `parseAmount` silently
    /// clamps a parse failure to 0, which is right for *booking* (nothing
    /// entered) but wrong for *validating* (garbage entered) — this is the
    /// check `canSubmit` needs to tell those two apart.
    private var floatBackIsValid: Bool {
        parsedAmountIfValid(floatBackText) != nil
    }

    /// Geparste Rücklage-Beträge je Automat im Mehrfach-Modus, keyed by
    /// machine id — eine Zeile pro `breakdownMachines`-Eintrag. Nutzt
    /// denselben `parseAmount`-Helper wie `floatBack`, damit beide Felder
    /// garantiert identisch parsen. Nullbeträge bleiben harmlos enthalten;
    /// ViewModel und RPC überspringen sie ohnehin beim Buchen.
    private var multiFloats: [UUID: Double] {
        Dictionary(uniqueKeysWithValues: breakdownMachines.map {
            ($0.machineId, parseAmount(multiFloatTexts[$0.machineId] ?? ""))
        })
    }

    /// Whether every per-machine Rücklage row parses cleanly — same
    /// empty-is-valid / garbage-is-invalid distinction as `floatBackIsValid`,
    /// applied per row.
    private var multiFloatsAreValid: Bool {
        breakdownMachines.allSatisfy {
            parsedAmountIfValid(multiFloatTexts[$0.machineId] ?? "") != nil
        }
    }

    /// Summe der Rücklage über alle Eingabewege — im Mehrfach-Modus alle
    /// Zeilen, sonst das einzelne Feld. Basis für `netToBox`.
    private var totalFloatBack: Double {
        isMultiMachine ? multiFloats.values.reduce(0, +) : floatBack
    }

    /// Was nach der Rücklage tatsächlich in der Kasse landet.
    private var netToBox: Double {
        counted - totalFloatBack
    }

    /// Sobald eine Rücklage erfasst wird, ist der Automatenbezug zwingend —
    /// unabhängig von `trackPerMachine`, das nur den Erwartungswert verankert.
    /// Im Mehrfach-Modus entfällt diese Pflicht: jede Zeile trägt ihren
    /// eigenen Automaten bereits in `multiFloats`, ein zusätzlicher
    /// Top-Level-Automat wäre überflüssig und darf die Buchung nicht
    /// blockieren.
    private var machineRequired: Bool {
        !isMultiMachine && floatBack > 0
    }

    private var canSubmit: Bool {
        counted > 0
            && (!machineRequired || selectedMachineId != nil)
            // An unparseable float amount must never silently book as 0 —
            // block submission until it's fixed or cleared.
            && (isMultiMachine ? multiFloatsAreValid : floatBackIsValid)
    }

    /// Whether the input contains an operator — drives the "= 25,50 €" preview.
    private var isExpression: Bool {
        countedText.contains(where: { "+-*/×".contains($0) })
    }

    /// Machines scoped to *this sheet's* cashBook (not the VM's selected one).
    private var assignedMachines: [CashBookMachineRef] {
        cashBookVM.assignedMachines(for: cashBook.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                expectedSection
                countedSection
                floatBackSection

                Section("cash_book_description") {
                    TextField(text: $description) {
                        Text(verbatim: "")
                    }
                }

                // The machine attribution of the withdrawal *itself* is
                // independent of isMultiMachine — a per-machine float row
                // (multiFloatSection) only decides where the Rücklage is
                // booked, not which machine(s) this withdrawal emptied.
                // Hiding this picker whenever a tour visited more than one
                // machine used to leave selectedMachineId stuck at nil,
                // which record_cash_book_withdrawal's anchor logic reads as
                // "this withdrawal emptied every machine on the Barkasse" —
                // silently advancing the anchor of machines that were never
                // actually collected. See fix-wave-e-report.md.
                if (cashBook.trackPerMachine || machineRequired) && !assignedMachines.isEmpty {
                    Section {
                        Picker("cash_book_from_machine", selection: $selectedMachineId) {
                            Text("—").tag(UUID?.none)
                            ForEach(assignedMachines) { m in
                                Text(m.name ?? String(m.id.uuidString.prefix(8)))
                                    .tag(UUID?.some(m.id))
                            }
                        }
                        .labelsHidden()
                    } header: {
                        Text("cash_book_from_machine")
                    } footer: {
                        // NULL is a legitimate choice (it means "this
                        // withdrawal emptied every machine on this
                        // Barkasse"), but a silent one — make the
                        // consequence visible instead of leaving the
                        // operator to guess. Suppressed when
                        // `emptiedMachineIds` is about to be sent instead —
                        // in that case a nil `selectedMachineId` no longer
                        // means "every machine", it means "exactly the
                        // visited subset", and this text would be false.
                        if cashBook.trackPerMachine && selectedMachineId == nil && emptiedMachineIds.isEmpty {
                            Text("cash_book_withdrawal_empties_all_machines")
                        }
                    }
                } else if machineRequired && assignedMachines.isEmpty {
                    Section {
                        Text("cash_book_no_assigned_machine_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("cash_book_record_withdrawal")
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
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("cash_book_book_entry")
                        }
                    }
                    .disabled(isSubmitting || !canSubmit)
                }
            }
            .task {
                // Always load fresh theoretical cash for the cash book this
                // sheet is for — even if the VM's selectedCashBookId points
                // elsewhere (multi-Barkasse refill case).
                await loadTheoretical()
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var expectedSection: some View {
        Section {
            LabeledContent {
                Text(expected, format: .currency(code: "EUR"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            } label: {
                Text("cash_book_expected_max")
            }
            if !breakdownMachines.isEmpty {
                ForEach(breakdownMachines) { m in
                    HStack {
                        Text(m.machineName ?? "—").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("+\(NumberFormatter.localizedString(from: m.cashSales as NSNumber, number: .currency))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("cash_book_changer_hint")
                .font(.caption)
                .italic()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var countedSection: some View {
        Section("cash_book_counted_amount") {
            HStack(alignment: .firstTextBaseline) {
                TextField("0,00", text: $countedText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .focused($countedFieldFocused)
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            if countedFieldFocused {
                                calculatorToolbar
                            }
                        }
                    }

                // Inline evaluated preview when the input is an expression
                if isExpression, counted > 0 {
                    Text(verbatim: "= \(amountFormatted(counted))")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                }
            }

            if abs(difference) > 0.001 && counted > 0 {
                Text(differenceLabel)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Verzweigt zwischen dem bisherigen Einzel-Feld (ein Automat oder
    /// manuelle Entnahme — unverändertes Verhalten) und der Mehrfach-Zeilen-
    /// Ansicht (`isMultiMachine`). Header/Footer bleiben in beiden Fällen
    /// dieselben Strings, da sich der Zweck nicht ändert — nur, ob der
    /// Betrag in ein Feld oder auf mehrere Automaten aufgeteilt wird.
    @ViewBuilder
    private var floatBackSection: some View {
        if isMultiMachine {
            multiFloatSection
        } else {
            singleFloatSection
        }
    }

    @ViewBuilder
    private var singleFloatSection: some View {
        Section {
            TextField("0,00", text: $floatBackText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(floatBackIsValid ? Color.primary : Color.red)

            if !floatBackIsValid {
                Text("cash_book_amount_invalid")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if floatBack > 0 {
                LabeledContent {
                    Text(netToBox, format: .currency(code: "EUR"))
                        .monospacedDigit()
                } label: {
                    Text("cash_book_net_to_box")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("cash_book_float_back")
        } footer: {
            Text("cash_book_float_back_hint")
        }
    }

    /// Eine Zeile je besuchtem Automaten dieser Barkasse (`breakdownMachines`
    /// — bereits auf `tourMachineIds` gescoped). Jede Zeile parst identisch
    /// zum Einzel-Feld (`parseAmount`); die Summe treibt `netToBox`.
    ///
    /// `breakdownMachines` can be empty even while `isMultiMachine` is true:
    /// it derives from `theoretical`, which the view model nils out on any
    /// load error, while `isMultiMachine` derives independently from
    /// `tourMachineIds`. Rendering the usual header + rows + footer in that
    /// state would show an empty section that still *claims* to handle a
    /// Rücklage — the user could submit believing a float was recorded when
    /// none was. Showing an explanatory message instead makes that outcome
    /// visible rather than silent.
    @ViewBuilder
    private var multiFloatSection: some View {
        if breakdownMachines.isEmpty {
            Section {
                Text("cash_book_float_breakdown_unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                ForEach(breakdownMachines) { m in
                    let rowText = multiFloatTextBinding(for: m.machineId)
                    let rowIsValid = parsedAmountIfValid(rowText.wrappedValue) != nil
                    HStack {
                        Text(m.machineName ?? String(m.machineId.uuidString.prefix(8)))
                        Spacer()
                        TextField("0,00", text: rowText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(rowIsValid ? Color.primary : Color.red)
                            .frame(maxWidth: 100)
                    }
                }

                if !multiFloatsAreValid {
                    Text("cash_book_amount_invalid")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if totalFloatBack > 0 {
                    LabeledContent {
                        Text(netToBox, format: .currency(code: "EUR"))
                            .monospacedDigit()
                    } label: {
                        Text("cash_book_net_to_box")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("cash_book_float_back")
            } footer: {
                Text("cash_book_float_back_hint")
            }
        }
    }

    /// Zwei-Wege-Binding auf `multiFloatTexts[machineId]`, mit "" als
    /// Default für einen noch nicht editierten Automaten.
    private func multiFloatTextBinding(for machineId: UUID) -> Binding<String> {
        Binding(
            get: { multiFloatTexts[machineId] ?? "" },
            set: { multiFloatTexts[machineId] = $0 }
        )
    }

    // MARK: - Calculator Toolbar (matches WarehouseView pattern)

    @ViewBuilder
    private var calculatorToolbar: some View {
        HStack(spacing: 8) {
            ForEach(["×", "+", "-", "/"], id: \.self) { op in
                Button {
                    countedText += op == "×" ? "*" : op
                } label: {
                    Text(op)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .frame(width: 44, height: 36)
                        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            // Evaluate & close keyboard
            Button {
                if let result = evaluateExpression(countedText), result > 0 {
                    countedText = formatForInput(result)
                }
                countedFieldFocused = false
            } label: {
                Text("=")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 36)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Evaluates the input as a decimal expression. Accepts:
    /// - direct numbers ("12,50" or "12.50")
    /// - sums/products/divisions ("10+5.50", "12*3", "100/4")
    /// Returns nil for empty / invalid / trailing-operator strings.
    private func evaluateExpression(_ text: String) -> Double? {
        // Normalise: comma → dot (DE keyboards), × → *
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)

        if cleaned.isEmpty { return nil }
        if let num = Double(cleaned) { return num }

        // Allow only digits, operators, and dots
        let allowed = CharacterSet(charactersIn: "0123456789+-*/.")
        guard cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        // Reject expressions ending in an operator
        guard let lastChar = cleaned.last, lastChar.isNumber else { return nil }

        // NSExpression treats integer/integer as integer division. To get
        // proper decimal semantics, append ".0" to integer-looking operands.
        // Simpler: evaluate via NSExpression and read .doubleValue.
        let expression = NSExpression(format: cleaned)
        guard let result = expression.expressionValue(with: nil, context: nil) as? NSNumber else {
            return nil
        }
        let value = result.doubleValue
        return value.isFinite && value > 0 ? value : nil
    }

    /// Gemeinsamer Parser für Rücklage-Beträge — genutzt vom Einzel-Feld
    /// (`floatBack`) und jeder Zeile im Mehrfach-Modus (`multiFloats`), damit
    /// beide garantiert identisch parsen und nicht auseinanderlaufen können.
    /// Trimmt Whitespace vor dem Parsen (`Double.init?` lehnt " 50 " sonst
    /// ab und würde die Eingabe still als 0 buchen), akzeptiert `,` als
    /// Dezimaltrennzeichen, und klemmt negative Ergebnisse auf 0 — die RPC
    /// negiert den Betrag intern selbst.
    ///
    /// For *booking*, an unparseable string collapses to 0 — that's the
    /// right behaviour once submission was already allowed. It is the wrong
    /// behaviour for *validating* the field, though: "1.234,50" (a
    /// thousands-separator format this parser doesn't accept) would
    /// otherwise book silently as 0,00 €, exactly where a silent zero costs
    /// money. `parsedAmountIfValid` is the validating counterpart `canSubmit`
    /// uses to catch that case before it reaches the RPC.
    private func parseAmount(_ text: String) -> Double {
        parsedAmountIfValid(text) ?? 0
    }

    /// Validating counterpart to `parseAmount`. Returns 0 for an empty field
    /// (nothing entered — valid, means "no Rücklage"), the parsed value for
    /// a well-formed non-negative one, and `nil` when the field is non-empty
    /// AND either fails to parse (garbage input) OR parses to a negative
    /// number — a negative Rücklage makes no sense and must be surfaced as
    /// an error like any other invalid input, not silently clamped to 0
    /// (which used to book the withdrawal as if nothing had been entered).
    private func parsedAmountIfValid(_ text: String) -> Double? {
        let cleaned = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        if cleaned.isEmpty { return 0 }
        guard let value = Double(cleaned), value >= 0 else { return nil }
        return value
    }

    private func amountFormatted(_ value: Double) -> String {
        NumberFormatter.localizedString(from: value as NSNumber, number: .currency)
    }

    /// Format a Double for inserting back into the text input — uses the
    /// user's locale-aware decimal separator (DE: `,`).
    private func formatForInput(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f.string(from: value as NSNumber) ?? String(format: "%.2f", value)
    }

    private var differenceLabel: String {
        let format = NSLocalizedString("cash_book_difference", comment: "")
        let diffStr = NumberFormatter.localizedString(from: abs(difference) as NSNumber, number: .currency)
        let countedStr = NumberFormatter.localizedString(from: counted as NSNumber, number: .currency)
        return String(format: format, diffStr, countedStr)
    }

    // MARK: - Data + Submit

    private func loadTheoretical() async {
        // If the VM's selection already points at our cashBook, refresh via
        // the VM (so the rest of the app sees the same fresh value) and copy
        // the snapshot. Otherwise do a one-shot RPC to avoid mutating
        // vm.theoreticalCash to the wrong Barkasse.
        if cashBookVM.selectedCashBookId == cashBook.id {
            await cashBookVM.loadTheoreticalCash(for: cashBook.id)
            theoretical = cashBookVM.theoreticalCash
        } else {
            theoretical = await cashBookVM.fetchTheoreticalCash(for: cashBook.id)
        }

        // When this sheet was opened from a tour that visited exactly one
        // machine of this Barkasse, pre-select it so the entry is attributed
        // correctly and the operator saves a tap. Only for tour-opened sheets
        // (tourMachineIds == nil for the manual withdrawal flow, which keeps
        // its "—" default); independent of `trackPerMachine`, which only
        // anchors the expected-cash figure, not whether the picker shows.
        if let tourMachineIds, selectedMachineId == nil {
            let visited = theoretical?.machineBreakdown(forMachines: tourMachineIds) ?? []
            if visited.count == 1 {
                selectedMachineId = visited.first?.machineId
            }
        }
    }

    private func submit() async {
        // `isSubmitting` is already `true` — set synchronously by the button
        // action. This `defer` is what clears it again, on every exit path
        // (including both guards below and a thrown error), so a failed
        // submit never leaves the button permanently disabled.
        defer { isSubmitting = false }
        // Final evaluation in case the user submits without tapping "="
        guard let evaluated = evaluateExpression(countedText), evaluated > 0 else {
            errorMessage = NSLocalizedString("cash_book_counted_amount", comment: "")
            return
        }
        guard isMultiMachine ? multiFloatsAreValid : floatBackIsValid else {
            errorMessage = NSLocalizedString("cash_book_amount_invalid", comment: "")
            return
        }
        errorMessage = nil
        do {
            try await cashBookVM.recordWithdrawal(
                cashBookId: cashBook.id,
                counted: evaluated,
                expected: expected,
                // Wenn `emptiedMachineIds` gesendet wird (Tour über >1
                // Automaten dieser Barkasse), muss `machineId` nil bleiben —
                // die RPC lehnt beide gleichzeitig ab. Sonst unverändert der
                // Picker-Wert (Einzel-Automat oder manuelle Entnahme).
                machineId: emptiedMachineIds.isEmpty ? selectedMachineId : nil,
                // Im Mehrfach-Modus geht die Rücklage ausschließlich über
                // `floats` — `floatBack` bleibt 0, damit die RPC-seitige
                // "p_float_back und p_floats schließen sich aus"-Prüfung nie
                // anschlägt (floatBackText wird im Mehrfach-Modus ohnehin nie
                // editiert, dieser Ternary macht es zusätzlich explizit).
                floatBack: isMultiMachine ? 0 : floatBack,
                description: description,
                floatDescription: totalFloatBack > 0
                    ? NSLocalizedString("cash_book_change_float_in", comment: "")
                    : nil,
                floats: isMultiMachine ? multiFloats : [:],
                emptiedMachineIds: emptiedMachineIds
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
