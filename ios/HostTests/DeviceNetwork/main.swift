import Foundation

// DeviceNetwork — the cases of the web's network.test.ts. Run via ./run.sh.

var failures = 0
var checks = 0

func expect<T: Equatable>(_ actual: T, _ expected: T, _ label: String, line: Int = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        print("FAIL [\(label)] line \(line):\n  got      \(String(describing: actual))\n  expected \(String(describing: expected))")
    }
}

// ── level ────────────────────────────────────────────────────────────────────

for (rssi, level) in [(-40, 4), (-55, 4), (-56, 3), (-67, 3), (-68, 2), (-75, 2), (-76, 1), (-85, 1), (-86, 0), (-100, 0)] {
    expect(DeviceNetwork.level(.wifi, rssi: rssi), level, "wifi \(rssi)")
}
for (rssi, level) in [(-50, 4), (-65, 4), (-66, 3), (-80, 3), (-81, 2), (-95, 2), (-96, 1), (-105, 1), (-106, 0)] {
    expect(DeviceNetwork.level(.cellular, rssi: rssi), level, "cellular \(rssi)")
}
expect(DeviceNetwork.level(.wifi, rssi: nil), nil, "no reading")
expect(DeviceNetwork.level(.wifi, rssi: 0), nil, "0 dBm = no reading")

// ── quality / tone ───────────────────────────────────────────────────────────

expect([0, 1, 2, 3, 4].map { DeviceNetwork.quality($0) }, [.none, .weak, .fair, .good, .excellent], "quality")
expect([0, 1, 2, 3, 4].map { DeviceNetwork.tone($0) }, [.bad, .weak, .ok, .ok, .ok], "tone")
expect(DeviceNetwork.quality(nil), nil, "quality nil")

// ── from ─────────────────────────────────────────────────────────────────────

expect(DeviceNetwork.from(network: nil, cellular: nil), nil, "no blocks")
expect(DeviceNetwork.from(network: NetworkBlock(uplink: "none"), cellular: nil), nil, "unknown uplink")

let measured = Date(timeIntervalSince1970: 1_793_966_400)
let wifi = DeviceNetwork.from(
    network: NetworkBlock(uplink: "wifi", ssid: "Büro-WLAN", rssi: -62, ip: "192.168.1.47", measuredAt: measured),
    cellular: nil
)
expect(wifi, DeviceNetwork(kind: .wifi, name: "Büro-WLAN", rssi: -62, level: 3, quality: .good, tone: .ok,
                           mode: nil, ip: "192.168.1.47", measuredAt: measured), "wifi block")

let cell = DeviceNetwork.from(
    network: NetworkBlock(uplink: "cellular", op: "Telekom.de", rssi: -78, mode: "LTE-M", ip: "10.0.0.1"),
    cellular: nil
)
expect(cell?.kind, .cellular, "cellular kind")
expect(cell?.name, "Telekom.de", "cellular name")
expect(cell?.mode, "LTE-M", "cellular mode")
expect(cell?.level, 3, "cellular level")

let legacy = DeviceNetwork.from(network: nil, cellular: NetworkBlock(uplink: "cellular", op: "Vodafone DE", rssi: -100, mode: "NB-IoT"))
expect(legacy?.name, "Vodafone DE", "legacy name")
expect(legacy?.tone, .weak, "legacy tone")
expect(legacy?.measuredAt, nil, "legacy measured")

let prefer = DeviceNetwork.from(
    network: NetworkBlock(uplink: "wifi", ssid: "Office", rssi: -90),
    cellular: NetworkBlock(uplink: "cellular", op: "Telekom.de", rssi: -70)
)
expect(prefer?.kind, .wifi, "network block wins")
expect(prefer?.tone, .bad, "network block tone")

let placeholders = DeviceNetwork.from(network: NetworkBlock(uplink: "cellular", op: "unknown", rssi: 0, mode: "?", ip: "0.0.0.0"), cellular: nil)
expect(placeholders?.name, nil, "placeholder op")
expect(placeholders?.ip, nil, "placeholder ip")
expect(placeholders?.mode, nil, "placeholder mode")
expect(placeholders?.rssi, nil, "placeholder rssi")

// ── lenient decoding ─────────────────────────────────────────────────────────

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
let odd = try! decoder.decode(NetworkBlock.self, from: Data(#"{"uplink":"wifi","ssid":42,"rssi":-61.6,"measured_at":"2026-11-06T12:00:00Z"}"#.utf8))
expect(odd.uplink, "wifi", "decode uplink")
expect(odd.ssid, nil, "decode drops wrong type")
expect(odd.rssi, -62, "decode rounds a float rssi")
expect(odd.measuredAt, ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z"), "decode date")

print(failures == 0 ? "OK — \(checks) checks" : "\(failures) of \(checks) checks failed")
exit(failures == 0 ? 0 : 1)
