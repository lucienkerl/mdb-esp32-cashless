import Foundation

/// One uplink block of `embeddeds.mdb_diagnostics` — `network` (WiFi or
/// cellular, written by the mqtt-webhook with `measured_at`) or the older
/// `cellular` block. Decodes leniently and never throws: a field of an
/// unexpected type is dropped instead of failing the whole machine list.
struct NetworkBlock: Codable, Equatable {
    var uplink: String? = nil
    var ssid: String? = nil
    var op: String? = nil
    var rssi: Int? = nil
    var mode: String? = nil
    var ip: String? = nil
    var measuredAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case uplink, ssid, op, rssi, mode, ip
        case measuredAt = "measured_at"
    }

    init(uplink: String? = nil, ssid: String? = nil, op: String? = nil, rssi: Int? = nil,
         mode: String? = nil, ip: String? = nil, measuredAt: Date? = nil) {
        self.uplink = uplink
        self.ssid = ssid
        self.op = op
        self.rssi = rssi
        self.mode = mode
        self.ip = ip
        self.measuredAt = measuredAt
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        uplink = (try? c.decodeIfPresent(String.self, forKey: .uplink)) ?? nil
        ssid = (try? c.decodeIfPresent(String.self, forKey: .ssid)) ?? nil
        op = (try? c.decodeIfPresent(String.self, forKey: .op)) ?? nil
        if let i = (try? c.decodeIfPresent(Int.self, forKey: .rssi)) ?? nil {
            rssi = i
        } else if let d = (try? c.decodeIfPresent(Double.self, forKey: .rssi)) ?? nil, d.isFinite {
            rssi = Int(d.rounded())
        }
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        ip = (try? c.decodeIfPresent(String.self, forKey: .ip)) ?? nil
        measuredAt = (try? c.decodeIfPresent(Date.self, forKey: .measuredAt)) ?? nil
    }
}

/// Which network a device is on and how good its signal is. 1:1 port of
/// `management-frontend/app/lib/network.ts` (same thresholds, same cases in
/// `HostTests/DeviceNetwork`).
struct DeviceNetwork: Equatable {
    enum Kind: String, Equatable { case wifi, cellular }
    enum Quality: String, Equatable { case excellent, good, fair, weak, none }
    /// How the signal is painted: only weak and none draw attention.
    enum Tone: Equatable { case ok, weak, bad }

    let kind: Kind
    /// SSID on WiFi, operator on cellular.
    let name: String?
    let rssi: Int?
    /// 0–4 bars / arcs; nil when no signal value is known.
    let level: Int?
    let quality: Quality?
    let tone: Tone?
    /// Radio mode on cellular (LTE-M, NB-IoT …).
    let mode: String?
    let ip: String?
    /// When the signal was last sampled; nil for the legacy `cellular` block.
    let measuredAt: Date?

    /// Lower dBm limit for 4, 3, 2 and 1 bars.
    static func thresholds(_ kind: Kind) -> [Int] {
        switch kind {
        case .wifi: return [-55, -67, -75, -85]
        case .cellular: return [-65, -80, -95, -105]
        }
    }

    static func level(_ kind: Kind, rssi: Int?) -> Int? {
        // 0 dBm is what the firmware reports when it has no reading.
        guard let rssi, rssi < 0 else { return nil }
        let t = thresholds(kind)
        if rssi >= t[0] { return 4 }
        if rssi >= t[1] { return 3 }
        if rssi >= t[2] { return 2 }
        if rssi >= t[3] { return 1 }
        return 0
    }

    static func quality(_ level: Int?) -> Quality? {
        guard let level else { return nil }
        let all: [Quality] = [.none, .weak, .fair, .good, .excellent]
        return all[max(0, min(4, level))]
    }

    static func tone(_ level: Int?) -> Tone? {
        guard let level else { return nil }
        if level >= 2 { return .ok }
        return level == 1 ? .weak : .bad
    }

    private static func clean(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
              s != "unknown", s != "0.0.0.0", s != "?" else { return nil }
        return s
    }

    static func from(network: NetworkBlock?, cellular: NetworkBlock?) -> DeviceNetwork? {
        let block: NetworkBlock
        if let network, network.uplink == "wifi" || network.uplink == "cellular" {
            block = network
        } else if let cellular, cellular.uplink == "cellular" {
            block = cellular
        } else {
            return nil
        }
        let kind: Kind = block.uplink == "wifi" ? .wifi : .cellular
        let level = level(kind, rssi: block.rssi)
        return DeviceNetwork(
            kind: kind,
            name: kind == .wifi ? clean(block.ssid) : clean(block.op),
            rssi: level == nil ? nil : block.rssi,
            level: level,
            quality: quality(level),
            tone: tone(level),
            mode: kind == .cellular ? clean(block.mode) : nil,
            ip: clean(block.ip),
            measuredAt: block.measuredAt
        )
    }
}
