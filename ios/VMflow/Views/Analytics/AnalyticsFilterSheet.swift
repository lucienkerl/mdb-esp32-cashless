// ios/VMflow/Views/Analytics/AnalyticsFilterSheet.swift
import SwiftUI

struct AnalyticsFilterSheet: View {
  @EnvironmentObject var filter: AnalyticsFilter
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Date range") {
          DatePicker("From", selection: $filter.from, displayedComponents: .date)
          DatePicker("To",   selection: $filter.to,   displayedComponents: .date)
          Toggle("Compare period", isOn: $filter.compare)
        }
        // TODO Chunk 6: Machines / Channels / Categories / VAT rates pickers
      }
      .navigationTitle("Filters")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Reset") {
            filter.from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
            filter.to = Date()
            filter.compare = false
            filter.machines = []
            filter.channels = []
            filter.categories = []
            filter.vatRates = []
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }.fontWeight(.semibold)
        }
      }
    }
  }
}
