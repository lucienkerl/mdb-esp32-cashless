// ios/VMflow/Models/AnalyticsFilter.swift
import Foundation
import Combine
import SwiftUI

/// Shared filter state for the iOS Analytics surface. Mirrors the
/// `AnalyticsFilter` shape used by the web `useAnalyticsFilters` composable
/// so URL/preset payloads round-trip across platforms.
///
/// Key behaviour:
/// - `v` is always 1 on encode and clamped to 1 on decode (forward-compat).
/// - Unknown keys in incoming JSON are silently dropped (decoder ignores
///   keys not in `CodingKeys`).
/// - `defaultValue` returns a fresh instance (not a singleton) since each
///   AnalyticsRootView gets its own @StateObject.
final class AnalyticsFilter: ObservableObject, Codable {
  @Published var v: Int = 1
  @Published var from: Date
  @Published var to: Date
  @Published var compare: Bool = false
  @Published var machines: [String] = []
  @Published var channels: [String] = []
  @Published var categories: [String] = []
  @Published var vatRates: [Double] = []

  /// Returns a fresh instance with `from = -30d`, `to = now`. NOT a singleton —
  /// each call constructs a new object. Use as `@StateObject private var filter = AnalyticsFilter.defaultValue`.
  static var defaultValue: AnalyticsFilter {
    AnalyticsFilter()
  }

  init() {
    self.from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    self.to = Date()
  }

  enum CodingKeys: String, CodingKey {
    case v, from, to, compare, machines, channels, categories, vatRates
  }

  required init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.v = 1   // always clamp
    self.from = try c.decode(Date.self, forKey: .from)
    self.to = try c.decode(Date.self, forKey: .to)
    self.compare = (try? c.decode(Bool.self, forKey: .compare)) ?? false
    self.machines = (try? c.decode([String].self, forKey: .machines)) ?? []
    self.channels = (try? c.decode([String].self, forKey: .channels)) ?? []
    self.categories = (try? c.decode([String].self, forKey: .categories)) ?? []
    self.vatRates = (try? c.decode([Double].self, forKey: .vatRates)) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(1, forKey: .v)
    try c.encode(from, forKey: .from)
    try c.encode(to, forKey: .to)
    try c.encode(compare, forKey: .compare)
    try c.encode(machines, forKey: .machines)
    try c.encode(channels, forKey: .channels)
    try c.encode(categories, forKey: .categories)
    try c.encode(vatRates, forKey: .vatRates)
  }
}
