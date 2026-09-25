import Foundation

// MARK: - API Response

struct DealSearchResponse: Codable {
    let deals: [Deal]
    let fromCache: Bool
    let searchedProducts: Int?
    let totalDeals: Int?
}

// MARK: - Deal Model

struct Deal: Codable, Identifiable {
    let id: UUID
    let productId: UUID?
    let keywordId: UUID?
    let matchedTerm: String?
    let retailer: String
    let dealTitle: String
    let dealPrice: Double?
    let regularPrice: Double?
    let discountPct: Double?
    let validFrom: String?
    let validUntil: String?
    let imageUrl: String?
    let imageUrlLarge: String?
    let sourceUrl: String?
    let externalUrl: String?
    let matchedBy: String
    let confidence: Double
    let matchedTokens: [String]?
    let requiresApp: Bool
    let fetchedAt: String
    let offerId: String?
    let products: DealProduct?
    let dealKeywords: DealKeywordMatch?

    enum CodingKeys: String, CodingKey {
        case id, retailer, confidence, products
        case productId = "product_id"
        case keywordId = "keyword_id"
        case matchedTerm = "matched_term"
        case dealTitle = "deal_title"
        case dealPrice = "deal_price"
        case regularPrice = "regular_price"
        case discountPct = "discount_pct"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
        case imageUrl = "image_url"
        case imageUrlLarge = "image_url_large"
        case sourceUrl = "source_url"
        case externalUrl = "external_url"
        case matchedBy = "matched_by"
        case matchedTokens = "matched_tokens"
        case requiresApp = "requires_app"
        case fetchedAt = "fetched_at"
        case offerId = "offer_id"
        case dealKeywords = "deal_keywords"
    }

    // MARK: - Formatted Properties

    var formattedDealPrice: String? {
        guard let price = dealPrice else { return nil }
        return String(format: "%.2f \u{20AC}", price)
    }

    var formattedRegularPrice: String? {
        guard let price = regularPrice else { return nil }
        return String(format: "%.2f \u{20AC}", price)
    }

    var formattedDiscount: String? {
        guard let pct = discountPct, pct > 0 else { return nil }
        return "-\(Int(pct))%"
    }

    var productName: String {
        if let name = products?.name { return name }
        if let label = dealKeywords?.label, !label.isEmpty { return label }
        if let firstTerm = dealKeywords?.terms?.first, !firstTerm.isEmpty { return firstTerm }
        if let firstLinked = dealKeywords?.linkedProducts.first?.name { return firstLinked }
        if let term = matchedTerm, !term.isEmpty { return term }
        return "Unknown Product"
    }

    var productImagePath: String? {
        products?.imagePath ?? dealKeywords?.linkedProducts.first?.imagePath
    }

    var productSellprice: Double? {
        products?.sellprice ?? dealKeywords?.linkedProducts.first?.sellprice
    }

    // MARK: - Validity

    enum ValidityStatus {
        case upcoming, active, expiring, expired

        var label: String {
            switch self {
            case .upcoming: return String(localized: "Not valid yet")
            case .active: return String(localized: "Active")
            case .expiring: return String(localized: "Expiring soon")
            case .expired: return String(localized: "Expired")
            }
        }
    }

    /// Calendar-day validity, mirroring the web's `app/lib/dealValidity.ts` —
    /// keep both in sync. `valid_from`/`valid_until` are DATE columns holding
    /// calendar days in the company's timezone, so they're parsed as local
    /// days. The upcoming check deliberately doesn't require an end date: a
    /// deal without `valid_until` used to read as `.active` even when it only
    /// started next week.
    var validityStatus: ValidityStatus {
        let today = Calendar.current.startOfDay(for: Date())
        if let until = validUntilDate, until < today { return .expired }
        if let from = validFromDate, from > today { return .upcoming }
        if let until = validUntilDate, Self.days(from: today, to: until) <= 2 { return .expiring }
        return .active
    }

    var isValid: Bool {
        guard let until = validUntilDate else { return true }
        return until >= Calendar.current.startOfDay(for: Date())
    }

    /// True when the deal can be bought today (not upcoming, not expired).
    var isValidToday: Bool {
        validityStatus == .active || validityStatus == .expiring
    }

    var validFromDate: Date? { validFrom.flatMap(Self.parseDay) }
    var validUntilDate: Date? { validUntil.flatMap(Self.parseDay) }

    /// Whole days until the deal starts (≥ 1), only while it is upcoming.
    var startsInDays: Int? {
        guard validityStatus == .upcoming, let from = validFromDate else { return nil }
        return Self.days(from: Calendar.current.startOfDay(for: Date()), to: from)
    }

    var formattedValidUntil: String? {
        validUntilDate.map { Self.displayFormatter.string(from: $0) }
    }

    var formattedValidFrom: String? {
        validFromDate.map { Self.displayFormatter.string(from: $0) }
    }

    /// "valid from Mon, 28.09." — weekday first, since "is it Monday yet?"
    /// is the question when deciding whether to drive to the store.
    var validFromLabel: String? {
        validFromDate.map { String(format: String(localized: "valid from %@"), Self.shortDay($0)) }
    }

    /// "tomorrow" / "in 3 days".
    var startsInLabel: String? {
        startsInDays.map(Self.relativeDaysLabel)
    }

    static func relativeDaysLabel(_ days: Int) -> String {
        days == 1
            ? String(localized: "tomorrow")
            : String(format: String(localized: "in %lld days"), days)
    }

    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day(.twoDigits).month(.twoDigits))
    }

    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Sort rank for "valid today first, then upcoming, then expired".
    var validityRank: Int {
        switch validityStatus {
        case .active, .expiring: return 0
        case .upcoming: return 1
        case .expired: return 2
        }
    }

    // MARK: - Confidence

    enum ConfidenceLevel {
        case high, medium, low

        init(value: Double) {
            if value >= 0.85 { self = .high }
            else if value >= 0.65 { self = .medium }
            else { self = .low }
        }
    }

    var confidenceLevel: ConfidenceLevel {
        ConfidenceLevel(value: confidence)
    }

    var formattedConfidence: String {
        "\(Int(confidence * 100))%"
    }

    // MARK: - Date Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    /// Local midnight of a `YYYY-MM-DD` value (tolerates a timestamp suffix).
    private static func parseDay(_ value: String) -> Date? {
        dateFormatter.date(from: String(value.prefix(10)))
    }

    private static func days(from: Date, to: Date) -> Int {
        Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
    }
}

// MARK: - Deal Product (joined relation)

struct DealProduct: Codable {
    let id: UUID?
    let name: String?
    let imagePath: String?
    let sellprice: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, sellprice
        case imagePath = "image_path"
    }
}

// MARK: - Deal Keyword (joined relation for keyword-match rows)

/// Keyword group info embedded via PostgREST nested select when a deal was
/// matched against a user-defined keyword group rather than a single product.
/// The `deal_keyword_products` side returns rows like `{ products: {...} }`,
/// which we flatten into `linkedProducts` for convenient access.
struct DealKeywordMatch: Codable {
    let id: UUID?
    let label: String?
    let terms: [String]?
    let linkedProducts: [DealProduct]

    private struct LinkedProductRow: Codable {
        let products: DealProduct?
    }

    enum CodingKeys: String, CodingKey {
        case id, label, terms
        case dealKeywordProducts = "deal_keyword_products"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        terms = try c.decodeIfPresent([String].self, forKey: .terms)
        let rows = try c.decodeIfPresent([LinkedProductRow].self, forKey: .dealKeywordProducts) ?? []
        linkedProducts = rows.compactMap { $0.products }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id, forKey: .id)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(terms, forKey: .terms)
        let rows = linkedProducts.map { LinkedProductRow(products: $0) }
        try c.encode(rows, forKey: .dealKeywordProducts)
    }
}

// MARK: - Deal User State (archived / pinned per user)

/// Per-user annotation on a deal, keyed by (retailer, offer_id) on the server.
/// Rows only exist for deals the user has interacted with; absence of a row
/// means not-archived and not-pinned.
struct DealUserStateRow: Codable {
    let retailer: String
    let offerId: String
    let archivedAt: String?
    let pinnedAt: String?

    enum CodingKeys: String, CodingKey {
        case retailer
        case offerId = "offer_id"
        case archivedAt = "archived_at"
        case pinnedAt = "pinned_at"
    }
}

// MARK: - Deduplicated Deal

/// Collapses multiple deal_cache rows that share the same (retailer, offer_id)
/// into a single card. Brand-wide offers that fuzzy-matched many catalog
/// entries (e.g. "Red Bull versch. Sorten" matching every Red Bull variant)
/// used to render as N near-identical duplicates; now they appear as one card
/// with the full list of matched products accessible in the detail sheet.
struct DedupedDeal: Identifiable {
    /// Stable cross-refresh key — matches the server-side `deal_user_state`
    /// composite key (retailer, offer_id). Safe to use as SwiftUI Identifiable.
    let key: String
    let retailer: String
    let offerId: String
    let primary: Deal
    let matchedProducts: [MatchedProduct]
    let matchedKeywords: [DealKeywordMatch]
    let archived: Bool
    let pinned: Bool
    let pinnedAt: String?

    var id: String { key }

    struct MatchedProduct: Identifiable {
        let id: UUID
        let name: String
        let imagePath: String?
        let sellprice: Double?
        let confidence: Double
    }

    /// Forwards through to the underlying primary deal so existing UI helpers
    /// (formattedDealPrice, validityStatus, confidenceLevel, …) keep working
    /// without needing a parallel set of DedupedDeal computed properties.
    var dealTitle: String { primary.dealTitle }
    var requiresApp: Bool { primary.requiresApp }
    var discountPct: Double? { primary.discountPct }
    var confidence: Double { primary.confidence }
    var imageUrl: String? { primary.imageUrl }
    var imageUrlLarge: String? { primary.imageUrlLarge }
}

