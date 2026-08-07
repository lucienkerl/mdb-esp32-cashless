import Foundation

// MARK: - CashBook

struct CashBook: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let companyId: UUID
    let name: String
    let initialBalance: Double
    let bankDepositThreshold: Double
    let trackPerMachine: Bool
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case companyId = "company_id"
        case name
        case initialBalance = "initial_balance"
        case bankDepositThreshold = "bank_deposit_threshold"
        case trackPerMachine = "track_per_machine"
        case isActive = "is_active"
    }
}

// MARK: - CashBookEntry

enum CashBookEntryType: String, Codable {
    case initial
    case withdrawal
    case correction
    case payout
    case expense
    case changeFloat = "change_float"
    case reversal
    /// Forward-compat: unknown raw values (e.g. a future server type) decode
    /// here instead of throwing and failing the whole entries list.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CashBookEntryType(rawValue: raw) ?? .unknown
    }
}

struct CashBookEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let cashBookId: UUID
    let companyId: UUID
    let entryNumber: Int
    let type: CashBookEntryType
    let amount: Double
    let balanceAfter: Double
    let description: String?
    let machineId: UUID?
    let countedAmount: Double?
    let expectedAmount: Double?
    let category: String?
    let receiptReference: String?
    let correctsEntryId: UUID?
    let isReversed: Bool
    let createdBy: UUID
    let hash: String

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case cashBookId = "cash_book_id"
        case companyId = "company_id"
        case entryNumber = "entry_number"
        case type
        case amount
        case balanceAfter = "balance_after"
        case description
        case machineId = "machine_id"
        case countedAmount = "counted_amount"
        case expectedAmount = "expected_amount"
        case category
        case receiptReference = "receipt_reference"
        case correctsEntryId = "corrects_entry_id"
        case isReversed = "is_reversed"
        case createdBy = "created_by"
        case hash
    }
}

// MARK: - TheoreticalCash (RPC payload)

struct TheoreticalCash: Codable, Hashable {
    let theoreticalBalance: Double
    let lastEntryBalance: Double
    let cashSalesSince: Double
    let lastEntryAt: Date
    let entryCount: Int
    let machines: [PerMachineCashSales]

    struct PerMachineCashSales: Codable, Hashable, Identifiable {
        var id: UUID { machineId }
        let machineId: UUID
        let machineName: String?
        let cashSales: Double

        enum CodingKeys: String, CodingKey {
            case machineId = "machine_id"
            case machineName = "machine_name"
            case cashSales = "cash_sales"
        }
    }

    enum CodingKeys: String, CodingKey {
        case theoreticalBalance = "theoretical_balance"
        case lastEntryBalance = "last_entry_balance"
        case cashSalesSince = "cash_sales_since"
        case lastEntryAt = "last_entry_at"
        case entryCount = "entry_count"
        case machines
    }
}

extension TheoreticalCash {
    /// Expected cash limited to a subset of the Barkasse's machines — those
    /// physically visited on a refill tour. `cashSalesSince` sums *every*
    /// machine assigned to the Barkasse, so using it after a partial tour
    /// implies the operator emptied machines they never touched. Passing the
    /// visited machine IDs scopes the figure to what was actually collected.
    ///
    /// `machineIds == nil` → the full `cashSalesSince` (a manual, whole-
    /// Barkasse withdrawal). A single-machine Barkasse, or a tour that visited
    /// every assigned machine, yields the same value as `cashSalesSince`.
    func expectedCash(forMachines machineIds: Set<UUID>?) -> Double {
        guard let machineIds else { return cashSalesSince }
        return machines
            .filter { machineIds.contains($0.machineId) }
            .reduce(0) { $0 + $1.cashSales }
    }

    /// The per-machine breakdown rows limited to `machineIds`, or all rows
    /// when `nil`. Mirrors `expectedCash(forMachines:)` so the displayed rows
    /// always add up to the displayed total.
    func machineBreakdown(forMachines machineIds: Set<UUID>?) -> [PerMachineCashSales] {
        guard let machineIds else { return machines }
        return machines.filter { machineIds.contains($0.machineId) }
    }
}

// MARK: - VendingMachine row used for cash-book wiring

/// A trimmed projection of `vendingMachine` that the cash-book layer needs.
/// Keeps the existing `Models/VendingMachine.swift` (used by the Machines feature)
/// untouched — that one has the full set of fields and a different `Codable`
/// shape. We use a separate, focused projection here to avoid coupling the two.
struct CashBookMachineRef: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String?
    let cashBookId: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case cashBookId = "cash_book_id"
    }
}

// MARK: - MachineChangeFloat (RPC payload)

/// Vorgestrecktes Wechselgeld je (Automat, Barkasse) aus
/// `get_machine_change_float`. Kein Tubenfüllstand — der ist von außen nicht
/// ermittelbar. Diese Zahl ändert sich ausschließlich durch eigene Buchungen.
struct MachineChangeFloat: Codable, Identifiable, Hashable {
    var id: String { "\(machineId.uuidString)-\(cashBookId.uuidString)" }
    let machineId: UUID
    let machineName: String?
    let cashBookId: UUID
    let floatBalance: Double
    let lastChangeAt: Date

    enum CodingKeys: String, CodingKey {
        case machineId = "machine_id"
        case machineName = "machine_name"
        case cashBookId = "cash_book_id"
        case floatBalance = "float_balance"
        case lastChangeAt = "last_change_at"
    }
}

// MARK: - ChangeFloatDirection

/// Richtung einer Wechselgeldbuchung aus Sicht der Barkasse. Die Oberfläche
/// fragt nie ein rohes Vorzeichen ab — Richtung plus nicht-negativer Betrag,
/// die Umrechnung passiert hier.
enum ChangeFloatDirection {
    case intoMachine
    case backToBox

    /// `amount` ist die Wirkung auf die Barkasse: eine Einlage senkt sie,
    /// eine Rücknahme hebt sie. Das Vorzeichen der Eingabe wird bewusst
    /// ignoriert — die Richtung entscheidet.
    func signedAmount(_ input: Double) -> Double {
        let magnitude = abs(input)
        return self == .intoMachine ? -magnitude : magnitude
    }
}
