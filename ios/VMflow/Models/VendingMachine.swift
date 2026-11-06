import Foundation

/// IoT device record. Maps to the `embeddeds` table.
struct Embedded: Codable, Identifiable, Equatable {
    let id: UUID
    let status: String?
    let statusAt: Date?
    let subdomain: Int
    let macAddress: String?
    let firmwareVersion: String?
    /// Additive fields for Device Health / MDB diagnostics — all optional with a
    /// default so existing call sites (previews) that construct `Embedded`
    /// directly keep compiling unchanged.
    ///
    /// These MUST stay `var`: Swift's synthesized `init(from:)` silently skips
    /// a `let` property that already has an initial value, so declaring them
    /// `let … = nil` leaves them permanently `nil` no matter what the server
    /// sent (the explicit `CodingKeys` below even suppresses the compiler
    /// warning that would otherwise flag it). That bug blanked the whole MDB
    /// Status card and made uptime fall back to `statusAt`.
    var firmwareBuildDate: Date? = nil
    var mdbAddress: Int? = nil
    /// Live MDB status snapshot published by the firmware. `nil` until the
    /// device has reported at least once.
    var mdbDiagnostics: MdbDiagnostics? = nil
    var lastRestartReason: String? = nil
    var lastRestartAt: Date? = nil
    /// Timestamp the device last transitioned to "online" — start of the
    /// current uptime run, distinct from `statusAt` (last status write of any
    /// kind).
    var onlineSince: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id, status, subdomain
        case statusAt = "status_at"
        case macAddress = "mac_address"
        case firmwareVersion = "firmware_version"
        case firmwareBuildDate = "firmware_build_date"
        case mdbAddress = "mdb_address"
        case mdbDiagnostics = "mdb_diagnostics"
        case lastRestartReason = "last_restart_reason"
        case lastRestartAt = "last_restart_at"
        case onlineSince = "online_since"
    }

    /// Online / no response / offline / updating — see `DeviceConnectivity`.
    func connectivity(now: Date = Date()) -> DeviceConnectivity {
        DeviceConnectivity.evaluate(status: status, statusAt: statusAt, onlineSince: onlineSince, mdbState: mdbDiagnostics?.state, now: now)
    }
}

/// Live MDB status snapshot, published by the firmware into
/// `embeddeds.mdb_diagnostics` (jsonb). Keys are camelCase because this side is
/// authored by the JS/TS ingest pipeline (mqtt-webhook), not a Postgres column.
struct MdbDiagnostics: Codable, Equatable {
    let state: String?
    let addr: String?
    let vmcLevel: Int?
    let polls: Int?
    let chkErr: Int?
    let lastCmd: String?
    let updatedAt: Date?
    /// Current uplink (WiFi or cellular) with signal — see `DeviceNetwork`.
    var network: NetworkBlock? = nil
    /// Older cellular-only block, read as a fallback by `DeviceNetwork`.
    var cellular: NetworkBlock? = nil

    enum CodingKeys: String, CodingKey {
        case state, addr, vmcLevel, polls, chkErr, lastCmd, network, cellular
        case updatedAt = "updated_at"
    }

    /// Which network the device is on and how good its signal is.
    var deviceNetwork: DeviceNetwork? {
        DeviceNetwork.from(network: network, cellular: cellular)
    }
}

/// One ESP32 reboot event. Maps to the `device_restarts` table.
struct DeviceRestart: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let reason: String
    let uptimeSec: Int?
    let firmwareVersion: String?
    let hwReason: String?

    enum CodingKeys: String, CodingKey {
        case id, reason
        case createdAt = "created_at"
        case uptimeSec = "uptime_sec"
        case firmwareVersion = "firmware_version"
        case hwReason = "hw_reason"
    }
}

/// One MDB state transition. Maps to the `mdb_log` table.
struct MdbLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let state: String
    let prevState: String?
    let addr: String?
    let polls: Int?
    let chkErr: Int?
    let lastCmd: String?

    enum CodingKeys: String, CodingKey {
        case id, state, addr, polls
        case createdAt = "created_at"
        case prevState = "prev_state"
        case chkErr = "chk_err"
        case lastCmd = "last_cmd"
    }
}

/// Vending machine record. Maps to the `vendingMachine` table.
/// Includes a nested `embeddeds` relation for device status.
struct VendingMachine: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String?
    let locationLat: Double?
    let locationLon: Double?
    let embedded: UUID?
    let countryCode: String?
    let embeddeds: Embedded?
    /// Additive settings fields. Defaulted via the explicit init below (not
    /// a stored-property default, since this struct has a custom init that
    /// assigns every property — a property default plus an init assignment
    /// would initialize the `let` twice) so existing call sites (previews)
    /// that construct `VendingMachine` directly keep compiling unchanged.
    let addressStreet: String?
    let addressHouseNumber: String?
    let addressPostalCode: String?
    let addressCity: String?
    let formattedAddress: String?
    let nayaxMachineId: String?
    let publicListing: Bool?
    /// Raw `linked_selections` column; read ``linkedSelections`` instead.
    /// Optional so the synthesized decoder uses `decodeIfPresent` and a
    /// select (or fixture, or older server) without the column still decodes.
    let linkedSelectionsRaw: Bool?

    /// The machine vends from a sibling slot when one of a product's slots is
    /// empty, so the "slot empty, product in another slot" hint is hidden.
    /// Display only; edited in the web app.
    var linkedSelections: Bool { linkedSelectionsRaw ?? false }

    enum CodingKeys: String, CodingKey {
        case id, name, embedded, embeddeds
        case locationLat = "location_lat"
        case locationLon = "location_lon"
        case countryCode = "country_code"
        case addressStreet = "address_street"
        case addressHouseNumber = "address_house_number"
        case addressPostalCode = "address_postal_code"
        case addressCity = "address_city"
        case formattedAddress = "formatted_address"
        case nayaxMachineId = "nayax_machine_id"
        case publicListing = "public_listing"
        case linkedSelectionsRaw = "linked_selections"
    }

    /// Explicit memberwise initializer. `let` properties that carry a default
    /// value at declaration (the additive fields below) are excluded from the
    /// compiler-synthesized memberwise init, so callers that need to set them
    /// explicitly (e.g. reconstructing after a save) need this instead.
    /// Defaults are kept on the additive params so existing call sites that
    /// only pass the original 7 fields keep compiling unchanged.
    init(
        id: UUID,
        name: String?,
        locationLat: Double?,
        locationLon: Double?,
        embedded: UUID?,
        countryCode: String?,
        embeddeds: Embedded?,
        addressStreet: String? = nil,
        addressHouseNumber: String? = nil,
        addressPostalCode: String? = nil,
        addressCity: String? = nil,
        formattedAddress: String? = nil,
        nayaxMachineId: String? = nil,
        publicListing: Bool? = nil,
        linkedSelections: Bool = false
    ) {
        self.id = id
        self.name = name
        self.locationLat = locationLat
        self.locationLon = locationLon
        self.embedded = embedded
        self.countryCode = countryCode
        self.embeddeds = embeddeds
        self.addressStreet = addressStreet
        self.addressHouseNumber = addressHouseNumber
        self.addressPostalCode = addressPostalCode
        self.addressCity = addressCity
        self.formattedAddress = formattedAddress
        self.nayaxMachineId = nayaxMachineId
        self.publicListing = publicListing
        self.linkedSelectionsRaw = linkedSelections
    }

    /// Display name, falling back to "Unnamed Machine".
    var displayName: String {
        name ?? String(localized: "Unnamed Machine")
    }

    /// Connectivity of the linked device; `.none` for a machine without one.
    func connectivity(now: Date = Date()) -> DeviceConnectivity {
        embeddeds?.connectivity(now: now) ?? .noDevice
    }
}

// MARK: - Per-machine computed statistics (populated after batch queries)

/// Enriched machine data with aggregated stats for display.
struct MachineStats: Identifiable, Equatable {
    let machine: VendingMachine
    var todayRevenue: Double = 0
    var todaySalesCount: Int = 0
    var yesterdayRevenue: Double = 0
    var yesterdaySalesCount: Int = 0
    var thisWeekRevenue: Double = 0
    var thisWeekSalesCount: Int = 0
    var lastWeekRevenue: Double = 0
    var lastWeekSalesCount: Int = 0
    var paxcounterCount: Int?

    // Stock health, warehouse-aware like the PWA's machine card
    // (`useMachines.ts`). `emptyTrays`/`lowTrays`/`fillTrays` count
    // **products** (all slots of a product form one group, see
    // `MachineStockHealth`) that need a refill *and* that the warehouse can
    // refill (every product counts as refillable when the company has no
    // warehouse stock at all). `lowTrays` is low-only, not low + empty.
    // `totalTrays` counts slots, unassigned ones included. Names kept for
    // compatibility.
    var totalTrays: Int = 0
    var lowTrays: Int = 0
    var emptyTrays: Int = 0
    var fillTrays: Int = 0
    /// Σ stock / Σ capacity over all slots (0…1); 0 when there is no capacity.
    var stockPercent: Double = 0
    /// Empty slots whose product is still stocked in another slot — a hint only.
    var emptySlotsWithStock: Int = 0

    // Products needing a refill the warehouse has no stock of — they never
    // drive `stockHealth`.
    var swapNeededCount: Int = 0   // sold out in every slot → swap the product
    var noStockCount: Int = 0      // low / top-off only

    /// Product ids with a positive batch in any warehouse, and whether any
    /// batch exists at all — the inputs of `applyStock(trays:)`.
    var warehouseProductIds: Set<UUID> = []
    var hasWarehouses = false

    // Per-product deficit info for card display: refillable products, then
    // swap candidates, then no-stock products.
    var trayDeficits: [TrayDeficit] = []

    var id: UUID { machine.id }

    /// Overall stock health: critical > low > fill > ok, driven only by
    /// refillable products.
    var stockHealth: StockHealth {
        if emptyTrays > 0 { return .critical }
        if lowTrays > 0 { return .low }
        if fillTrays > 0 { return .fill }
        return .ok
    }

    /// Sort priority: critical, low, fill, ok; within the same health more
    /// low + empty products first. Mirrors the PWA's machine list sort.
    var sortPriority: Int {
        let urgent = min(emptyTrays + lowTrays, 999)
        switch stockHealth {
        case .critical: return 1000 - urgent
        case .low: return 2000 - urgent
        case .fill: return 3000 - urgent
        case .ok: return 4000 - urgent
        }
    }
}

// MARK: - Stock roll-up (machine card + machine detail tile)

extension MachineStats {
    /// Recompute every stock field from the machine's trays. The single
    /// computation behind the machine card **and** the machine detail stock
    /// tile, so the two can never disagree. Uses `warehouseProductIds` /
    /// `hasWarehouses`, which the machine list fills in.
    mutating func applyStock(trays: [Tray]) {
        totalTrays = 0; lowTrays = 0; emptyTrays = 0; fillTrays = 0
        emptySlotsWithStock = 0; swapNeededCount = 0; noStockCount = 0
        trayDeficits = []

        // Trays / stock — judged per product, not per slot: all slots
        // of a product form one group (see `MachineStockHealth`), so a
        // product empty in one spiral but stocked in another is not
        // "out of stock". Warehouse-aware like the PWA's
        // `useMachines.ts`: only products the warehouse can refill
        // count towards Empty/Low/Top-off and the machine's colour;
        // the rest land in the no-stock list. Unassigned slots only
        // count towards the slot total and the stock percentage.
        totalTrays = trays.count

        let totalCapacity = trays.reduce(0) { $0 + $1.capacity }
        let totalStock = trays.reduce(0) { $0 + $1.currentStock }
        stockPercent = totalCapacity > 0 ? Double(totalStock) / Double(totalCapacity) : 0

        var refillDeficits: [TrayDeficit] = []
        var noStockDeficits: [TrayDeficit] = []

        let linked: Set<UUID> = machine.linkedSelections ? [machine.id] : []
        for group in MachineStockHealth.groupTraysByProduct(trays, linkedMachineIds: linked) {
            guard group.needsRefill else {
                emptySlotsWithStock += group.emptySlots
                continue
            }

            let severity: StockSeverity
            switch group.state {
            case .critical: severity = .critical
            case .low: severity = .low
            default: severity = .fillBelow
            }

            let refillable = MachineStockHealth.isProductRefillable(
                productId: group.productId,
                warehouseProductIds: warehouseProductIds,
                hasWarehouses: hasWarehouses
            )

            let first = group.trays[0]
            let deficit = TrayDeficit(
                productName: first.productName,
                imagePath: first.products?.imagePath,
                deficit: group.deficit,
                severity: severity,
                isDiscontinued: first.isDiscontinued,
                warehouseAvailability: refillable
                    ? .inStock
                    : (severity == .critical ? .needsSwap : .noStock)
            )

            if refillable {
                switch severity {
                case .critical: emptyTrays += 1
                case .low: lowTrays += 1
                case .fillBelow: fillTrays += 1
                }
                refillDeficits.append(deficit)
            } else {
                if severity == .critical { swapNeededCount += 1 } else { noStockCount += 1 }
                noStockDeficits.append(deficit)
            }
        }

        // Card order as in the PWA: refillable products, then swap
        // candidates, then dimmed no-stock products — each by deficit.
        let byDeficit: (TrayDeficit, TrayDeficit) -> Bool = { $0.deficit > $1.deficit }
        trayDeficits = refillDeficits.sorted(by: byDeficit)
            + noStockDeficits.filter { $0.warehouseAvailability == .needsSwap }.sorted(by: byDeficit)
            + noStockDeficits.filter { $0.warehouseAvailability != .needsSwap }.sorted(by: byDeficit)
    }
}

/// Machine stock health levels with associated colors. `fill` = only
/// top-off recommendations left (below `fill_when_below`).
enum StockHealth: String, Equatable, Codable {
    case ok
    case fill
    case low
    case critical
}

/// Severity level for individual tray/product stock deficits.
enum StockSeverity: Equatable, Comparable {
    case critical  // empty (currentStock == 0)
    case low       // below minStock
    case fillBelow // below fillWhenBelow
}

/// Warehouse stock availability for a product.
enum WarehouseAvailability: Equatable {
    case inStock      // Product available in warehouse (green "In Stock")
    case noStock      // Not in warehouse, tray still has some stock (dimmed "No Stock")
    case needsSwap    // Not in warehouse AND tray is empty (orange "Swap")
    case unknown      // No warehouse data available
}

/// Aggregated product deficit info for display on machine cards.
struct TrayDeficit: Equatable {
    let productName: String
    let imagePath: String?
    let deficit: Int
    let severity: StockSeverity
    let isDiscontinued: Bool
    let warehouseAvailability: WarehouseAvailability
}
