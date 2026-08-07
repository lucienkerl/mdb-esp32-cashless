import Foundation
import Supabase

/// Drives the Cash Book feature: list + entries + theoretical cash + writes.
@MainActor
final class CashBookViewModel: ObservableObject {
    // MARK: - Published State

    @Published private(set) var cashBooks: [CashBook] = []
    @Published var selectedCashBookId: UUID?
    @Published private(set) var entries: [CashBookEntry] = []
    @Published private(set) var theoreticalCash: TheoreticalCash?
    @Published private(set) var changeFloat: [MachineChangeFloat] = []
    /// True, wenn der Wechselgeldbestand nicht geladen werden konnte. Ohne das
    /// wäre "nicht Mitglied dieser Firma" (die RPC liefert dann NULL) von
    /// "kein Wechselgeld vorgestreckt" ([]) nicht zu unterscheiden.
    @Published private(set) var changeFloatUnavailable = false
    @Published private(set) var machines: [CashBookMachineRef] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingEntries = false
    @Published var error: String?

    /// Fixed expense categories (codes). Labels live in Localizable.xcstrings
    /// as cash_book_category_<code>.
    let expenseCategories = ["rent", "goods", "cleaning", "fees", "other"]

    private let client = SupabaseService.shared.client

    // MARK: - Computed

    var selectedCashBook: CashBook? {
        cashBooks.first { $0.id == selectedCashBookId }
    }

    /// Latest balance: first entry (DESC by entry_number) wins.
    var currentBalance: Double {
        entries.first?.balanceAfter ?? selectedCashBook?.initialBalance ?? 0
    }

    /// Most recent non-reversed payout. Invariant: `entries` is sorted DESC
    /// by `entry_number`, so the first match is the most recent one.
    var lastBankDeposit: CashBookEntry? {
        entries.first { $0.type == .payout && !$0.isReversed }
    }

    var machinesForSelectedCashBook: [CashBookMachineRef] {
        guard let id = selectedCashBookId else { return [] }
        return assignedMachines(for: id)
    }

    /// Returns machines assigned to the given cash book. Used by sheets
    /// that may be opened for a Barkasse different from `selectedCashBookId`
    /// (e.g. from the multi-Barkasse refill block).
    func assignedMachines(for cashBookId: UUID) -> [CashBookMachineRef] {
        machines.filter { $0.cashBookId == cashBookId }
    }

    /// Switch the active Barkasse and reload its entries + theoretical cash.
    /// Clears stale state before fetching so the UI doesn't briefly show the
    /// previous Barkasse's data in transit.
    func selectCashBook(_ id: UUID) async {
        guard id != selectedCashBookId else { return }
        // Clear stale state up-front
        entries = []
        theoreticalCash = nil
        selectedCashBookId = id
        await loadEntries(for: id)
        await loadTheoreticalCash(for: id)
    }

    /// Resolve a machine ID to a name for display.
    func machineName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return machines.first(where: { $0.id == id })?.name
    }

    // MARK: - Loading

    /// Fetches cash_books + machines in parallel, then reconciles selectedCashBookId.
    /// Spec §"Persistence & Lifecycle" enumerates the 5 reconciliation cases.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let booksTask: [CashBook] = client
                .from("cash_books")
                .select("*")
                .order("name")
                .execute()
                .value

            async let machinesTask: [CashBookMachineRef] = client
                .from("vendingMachine")
                .select("id, name, cash_book_id")
                .execute()
                .value

            let (books, fetchedMachines) = try await (booksTask, machinesTask)
            self.cashBooks = books
            self.machines = fetchedMachines
            reconcileSelection()
            await loadChangeFloat()

            // If we now have a selection, load its entries + theoretical cash
            if let id = selectedCashBookId {
                await loadEntries(for: id)
                await loadTheoreticalCash(for: id)
            }
        } catch is CancellationError {
            // SwiftUI cancels refreshable tasks routinely — silent
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func reconcileSelection() {
        // Spec §"Persistence & Lifecycle" — 5 cases, in order:
        // 1. cashBooks empty → nil
        if cashBooks.isEmpty {
            selectedCashBookId = nil
            return
        }
        // 2. stored ID still in cashBooks → keep
        if let id = selectedCashBookId, cashBooks.contains(where: { $0.id == id }) {
            return
        }
        // 3. stored ID gone → first alphabetically
        if selectedCashBookId != nil {
            selectedCashBookId = cashBooks.first?.id
            return
        }
        // 4. nil AND single Barkasse → auto-select
        if cashBooks.count == 1 {
            selectedCashBookId = cashBooks.first?.id
            return
        }
        // 5. nil AND multiple → leave nil (user must pick)
    }

    func loadEntries(for cashBookId: UUID) async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        do {
            let result: [CashBookEntry] = try await client
                .from("cash_book_entries")
                .select("*")
                .eq("cash_book_id", value: cashBookId)
                .order("entry_number", ascending: false)
                .execute()
                .value
            self.entries = result
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// One-shot fetch of theoretical cash for a specific Barkasse.
    /// Does NOT mutate `theoreticalCash`. Returns nil on error or when the
    /// RPC has nothing to say (no entries yet). Used by callers that need
    /// data for a Barkasse that is NOT `selectedCashBookId` (e.g. the
    /// multi-Barkasse refill block, or a `WithdrawalSheet` opened for
    /// a non-selected Barkasse).
    func fetchTheoreticalCash(for cashBookId: UUID) async -> TheoreticalCash? {
        guard let book = cashBooks.first(where: { $0.id == cashBookId }) else { return nil }
        struct Params: Encodable {
            let p_cash_book_id: UUID
            let p_company_id: UUID
        }
        do {
            let result: TheoreticalCash = try await client
                .rpc("get_theoretical_cash", params: Params(p_cash_book_id: cashBookId, p_company_id: book.companyId))
                .execute()
                .value
            return result
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    /// Loads theoretical cash for the *currently selected* Barkasse and
    /// writes it to the published `theoreticalCash` value. No-op if
    /// `cashBookId` does not match `selectedCashBookId` — for non-selected
    /// Barkassen, callers should use `fetchTheoreticalCash(for:)` instead
    /// to avoid clobbering app-wide state.
    func loadTheoreticalCash(for cashBookId: UUID) async {
        guard cashBookId == selectedCashBookId else { return }
        self.theoreticalCash = await fetchTheoreticalCash(for: cashBookId)
    }

    // MARK: - Mutations

    /// Bucht eine Entnahme, optional mit Wechselgeld-Rücklage in die Münztuben.
    /// Beide Zeilen entstehen serverseitig in einer Transaktion — eine gebuchte
    /// Entnahme ohne die zugehörige Rücklage würde den Kassenstand still
    /// überhöhen.
    ///
    /// `floatBack` wird als nicht-negativer Betrag übergeben; die RPC negiert
    /// intern. Ist `floatBack` ungleich null, ist `machineId` zwingend.
    func recordWithdrawal(
        cashBookId: UUID,
        counted: Double,
        expected: Double,
        machineId: UUID?,
        floatBack: Double = 0,
        description: String,
        floatDescription: String? = nil
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              client.auth.currentUser?.id != nil else {
            throw CashBookError.notAuthenticated
        }

        struct Params: Encodable {
            let p_cash_book_id: UUID
            let p_machine_id: UUID?
            let p_counted: Double
            let p_expected: Double
            let p_float_back: Double
            let p_description: String?
            let p_float_description: String?
        }

        struct Result: Decodable {
            let withdrawal_entry_id: UUID
            let change_float_entry_id: UUID?
        }

        let result: Result = try await client
            .rpc("record_cash_book_withdrawal", params: Params(
                p_cash_book_id: cashBookId,
                p_machine_id: machineId,
                p_counted: counted,
                p_expected: expected,
                p_float_back: floatBack,
                p_description: description.isEmpty ? nil : description,
                p_float_description: floatDescription
            ))
            .execute()
            .value

        await logCashBookEntryActivity(
            entryId: result.withdrawal_entry_id,
            cashBookId: cashBookId,
            companyId: companyId,
            type: "withdrawal",
            amount: counted,
            category: nil,
            description: description.isEmpty ? nil : description
        )

        if let floatEntryId = result.change_float_entry_id {
            await logCashBookEntryActivity(
                entryId: floatEntryId,
                cashBookId: cashBookId,
                companyId: companyId,
                type: "change_float",
                amount: -abs(floatBack),
                category: nil,
                description: floatDescription
            )
        }

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
        await loadChangeFloat()
    }

    /// Records a bank deposit (cash flowing OUT of the box to the bank).
    /// Caller passes a non-negative `amount`; we negate internally so the
    /// running balance decreases (matches web sign convention exactly).
    func recordBankDeposit(
        cashBookId: UUID,
        amount: Double,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let description: String?
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "payout",
            amount: -abs(amount),                 // NEGATIVE — money OUT of the box
            description: description,
            created_by: userId
        )

        let inserted: InsertedEntryId = try await client
            .from("cash_book_entries")
            .insert(row)
            .select("id")
            .single()
            .execute()
            .value

        await logCashBookEntryActivity(
            entryId: inserted.id,
            cashBookId: cashBookId,
            companyId: companyId,
            type: "payout",
            amount: row.amount,
            category: nil,
            description: description.isEmpty ? nil : description
        )

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
    }

    /// Records a cash expense (money OUT of the box for a business purpose).
    /// Caller passes a non-negative `amount`; we negate internally so the
    /// running balance decreases. category + receiptReference are required by
    /// the DB CHECK (GoBD).
    func recordExpense(
        cashBookId: UUID,
        amount: Double,
        category: String,
        receiptReference: String,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let category: String
            let receipt_reference: String
            let description: String?
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "expense",
            amount: -abs(amount),                 // NEGATIVE — money OUT of the box
            category: category,
            receipt_reference: receiptReference,
            description: description.isEmpty ? nil : description,
            created_by: userId
        )

        let inserted: InsertedEntryId = try await client
            .from("cash_book_entries")
            .insert(row)
            .select("id")
            .single()
            .execute()
            .value

        await logCashBookEntryActivity(
            entryId: inserted.id,
            cashBookId: cashBookId,
            companyId: companyId,
            type: "expense",
            amount: row.amount,
            category: category,
            description: row.description
        )

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
    }

    // MARK: - Wechselgeld (change_float)

    /// Lädt den vorgestreckten Wechselgeldbestand je Automat für die Firma.
    func loadChangeFloat() async {
        guard let companyId = cashBooks.first?.companyId else {
            changeFloat = []
            changeFloatUnavailable = false
            return
        }
        struct Params: Encodable { let p_company_id: UUID }
        do {
            // Optional dekodieren: NULL heißt "nicht Mitglied dieser Firma"
            // und ist etwas anderes als [] ("kein Wechselgeld vorgestreckt").
            let rows: [MachineChangeFloat]? = try await client
                .rpc("get_machine_change_float", params: Params(p_company_id: companyId))
                .execute()
                .value
            changeFloat = rows ?? []
            changeFloatUnavailable = (rows == nil)
        } catch is CancellationError {
            // SwiftUI cancels tasks routinely (tab switches, refreshable) —
            // silent, matching refresh()/loadEntries(). Must NOT flip
            // changeFloatUnavailable, which would show a spurious warning
            // for what is actually just an interrupted, retriable load.
        } catch {
            changeFloat = []
            changeFloatUnavailable = true
        }
    }

    /// Vorgestrecktes Wechselgeld eines Automaten, summiert über Barkassen —
    /// ein Automat kann die Barkasse gewechselt haben.
    func floatBalance(for machineId: UUID) -> Double {
        changeFloat
            .filter { $0.machineId == machineId }
            .reduce(0) { $0 + $1.floatBalance }
    }

    /// Bucht eine eigenständige Wechselgeldbewegung. `amount` ist bereits
    /// signiert (siehe `ChangeFloatDirection.signedAmount`).
    func recordChangeFloat(
        cashBookId: UUID,
        amount: Double,
        machineId: UUID,
        description: String
    ) async throws {
        guard let companyId = cashBooks.first(where: { $0.id == cashBookId })?.companyId,
              let userId = client.auth.currentUser?.id else {
            throw CashBookError.notAuthenticated
        }

        struct Insert: Encodable {
            let cash_book_id: UUID
            let company_id: UUID
            let type: String
            let amount: Double
            let description: String?
            let machine_id: UUID
            let created_by: UUID
        }

        let row = Insert(
            cash_book_id: cashBookId,
            company_id: companyId,
            type: "change_float",
            amount: amount,
            description: description.isEmpty ? nil : description,
            machine_id: machineId,
            created_by: userId
        )

        let inserted: InsertedEntryId = try await client
            .from("cash_book_entries")
            .insert(row)
            .select("id")
            .single()
            .execute()
            .value

        await logCashBookEntryActivity(
            entryId: inserted.id,
            cashBookId: cashBookId,
            companyId: companyId,
            type: "change_float",
            amount: amount,
            category: nil,
            description: description.isEmpty ? nil : description
        )

        await loadEntries(for: cashBookId)
        await loadTheoreticalCash(for: cashBookId)
        await loadChangeFloat()
    }

    // MARK: - Activity Log

    /// Decodes just the id of a freshly-inserted `cash_book_entries` row.
    private struct InsertedEntryId: Decodable { let id: UUID }

    /// Mirrors the PWA's `logActivity('cash_book_entry_created', …)` in
    /// `useCashBook.ts` so cash-book movements booked from iOS surface in the
    /// dashboard "Recent Activity" feed (on both iOS and web). There is no DB
    /// trigger — the activity_log row is written client-side, so iOS must do it
    /// too. Non-critical: failures are logged, never thrown, so a logging hiccup
    /// can't fail the entry itself. Metadata shape (type/amount/category/
    /// description + _user_* fields) matches what `ActivityFeed.swift` decodes.
    private func logCashBookEntryActivity(
        entryId: UUID?,
        cashBookId: UUID,
        companyId: UUID,
        type: String,
        amount: Double,
        category: String?,
        description: String?
    ) async {
        do {
            guard let user = client.auth.currentUser else { return }
            let firstName = user.userMetadata["first_name"]?.stringValue
            let lastName = user.userMetadata["last_name"]?.stringValue
            let fullName = [firstName, lastName].compactMap { $0 }
                .joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let userDisplay = fullName.isEmpty ? user.email : fullName

            let metadata: [String: AnyJSON] = [
                "cash_book_id": .string(cashBookId.uuidString),
                "type": .string(type),
                "amount": .double(amount),
                "category": category.map { .string($0) } ?? .null,
                "description": description.map { .string($0) } ?? .null,
                "_user_email": user.email.map { .string($0) } ?? .null,
                "_user_display": userDisplay.map { .string($0) } ?? .null,
            ]

            try await client
                .from("activity_log")
                .insert([
                    "company_id": AnyJSON.string(companyId.uuidString),
                    "user_id": AnyJSON.string(user.id.uuidString),
                    "entity_type": AnyJSON.string("cash_book"),
                    "entity_id": entryId.map { AnyJSON.string($0.uuidString) } ?? .null,
                    "action": AnyJSON.string("cash_book_entry_created"),
                    "metadata": AnyJSON.object(metadata),
                ])
                .execute()
        } catch {
            print("[CashBook] Activity log write failed: \(error)")
            // Non-critical — the entry itself already succeeded.
        }
    }

    // MARK: - Refill helpers

    /// Returns the cash books whose machines were visited in this set.
    func barkassenForVisitedMachines(_ machineIds: Set<UUID>) -> [CashBook] {
        let bookIds: Set<UUID> = Set(
            machines
                .filter { $0.cashBookId != nil && machineIds.contains($0.id) }
                .compactMap { $0.cashBookId }
        )
        return cashBooks.filter { bookIds.contains($0.id) }
    }
}

// MARK: - Errors

enum CashBookError: LocalizedError {
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        }
    }
}
