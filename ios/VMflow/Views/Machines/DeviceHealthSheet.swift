import SwiftUI

/// Device Health + MDB diagnostics, opened from a toolbar button on
/// `MachineDetailView`. Combines what the web splits across its "Device
/// Health" tab (uptime, restart history, auto-removed duplicates — all
/// roles) and its admin-only "MDB Diagnostics" tab (live MDB state + state
/// change history), plus the auto-removed-duplicates list that used to be
/// its own "Duplicates" tab here.
struct DeviceHealthSheet: View {
    @ObservedObject var detailViewModel: MachineDetailViewModel
    @EnvironmentObject private var auth: AuthService
    @Environment(\.dismiss) private var dismiss

    @State private var restarts: [DeviceRestart] = []
    @State private var mdbLogs: [MdbLogEntry] = []
    @State private var statusLog: [StatusLogRow] = []
    /// Ticks every 30 s so "contact 2 min ago" and the online → no response switch move on.
    @State private var now = Date()
    @State private var isLoadingRestarts = false
    @State private var isLoadingMdbLogs = false
    @State private var loadError: String?
    @State private var rowToRestore: SuppressedSale?

    private var embedded: Embedded? { detailViewModel.machine.embeddeds }
    private var isAdmin: Bool { auth.role == .admin }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                historySection
                if isAdmin { mdbDiagnosticsSection }
                restartHistorySection
                if isAdmin { mdbHistorySection }
                suppressedSection
            }
            .navigationTitle(String(localized: "Device Health"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
            .task(id: embedded?.status) {
                await loadStatusLog()
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    now = Date()
                }
            }
            .task {
                async let r: () = loadRestarts()
                if isAdmin {
                    async let m: () = loadMdbLogs()
                    _ = await (r, m)
                } else {
                    await r
                }
            }
            .alert(String(localized: "Error"), isPresented: .init(
                get: { loadError != nil }, set: { if !$0 { loadError = nil } }
            )) {
                Button(String(localized: "OK")) { loadError = nil }
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        let c = detailViewModel.machine.connectivity(now: now)
        Section(String(localized: "Connection")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(ConnectivityText.color(c.state))
                        .frame(width: 10, height: 10)
                    Text(ConnectivityText.state(c))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ConnectivityText.color(c.state))
                }
                Text(ConnectivityText.time(c, now: now))
                    .font(.subheadline)
                ConnectivityNotice(connectivity: c)
            }
            .padding(.vertical, 4)

            if c.state == .online, let since = c.onlineSince {
                LabeledContent(String(localized: "Online since"), value: "\(ConnectivityText.duration(now.timeIntervalSince(since))) (\(ConnectivityText.clock(since, now: now)))")
            }
            if c.state == .offline, let since = c.since, let start = c.onlineSince, since > start {
                LabeledContent(String(localized: "Online before that"), value: ConnectivityText.duration(since.timeIntervalSince(start)))
            }
            if c.state != .offline, let last = c.lastContactAt {
                LabeledContent(String(localized: "Last contact"), value: "\(ConnectivityText.ago(last, now: now)) (\(ConnectivityText.clock(last, now: now)))")
            }
            if let reader = c.reader {
                LabeledContent(String(localized: "Machine (MDB)"), value: ConnectivityText.reader(reader))
            }
            if let reason = embedded?.lastRestartReason, let at = embedded?.lastRestartAt {
                Text("\(restartReasonLabel(reason)) · \(at.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let history = StatusHistory.build(
            rows: statusLog,
            currentStatus: embedded?.status,
            windowStart: now.addingTimeInterval(-24 * 3600),
            now: now
        )
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ConnectionHistoryBar(history: history)
                HStack {
                    Text(String(localized: "24h ago"))
                    Spacer()
                    Text(String(localized: "now"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(ConnectionHistoryBar.percentLabel(history))
                    .font(.subheadline)
                ForEach(Array(history.outages.suffix(3).enumerated()), id: \.offset) { _, o in
                    let to = o.end >= now.addingTimeInterval(-1) ? String(localized: "now") : ConnectivityText.clock(o.end, now: now)
                    Text(String(localized: "Offline \(ConnectivityText.clock(o.start, now: now))–\(to) (\(ConnectivityText.duration(o.end.timeIntervalSince(o.start))))"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(String(localized: "Last 24 hours"))
        }
    }

    // MARK: - MDB Status (admin)

    private var mdbDiagnosticsSection: some View {
        Section {
            if let diag = embedded?.mdbDiagnostics {
                LabeledContent(String(localized: "State"), value: stateLabel(diag.state))
                if let addr = diag.addr {
                    LabeledContent(String(localized: "Address"), value: addr)
                }
                if let level = diag.vmcLevel {
                    LabeledContent(String(localized: "VMC Level"), value: "\(level)")
                }
                LabeledContent(String(localized: "Polls"), value: "\(diag.polls ?? 0)")
                LabeledContent(String(localized: "Checksum Errors"), value: "\(diag.chkErr ?? 0)")
                if let cmd = diag.lastCmd {
                    LabeledContent(String(localized: "Last Command"), value: cmd)
                }
            } else {
                Text(String(localized: "No MDB diagnostics yet.")).foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "MDB Status"))
        } footer: {
            // Same "Updated …" line the web shows under its MDB grid: the
            // snapshot is a last-known state, so its age is what tells you
            // whether it still means anything.
            if let updated = embedded?.mdbDiagnostics?.updatedAt {
                Text(String(localized: "Updated: \(updated.formatted(.relative(presentation: .named)))"))
            }
        }
    }

    // MARK: - Restart history

    private var restartHistorySection: some View {
        Section(String(localized: "Restart History")) {
            if isLoadingRestarts && restarts.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if restarts.isEmpty {
                Text(String(localized: "No restarts recorded.")).foregroundStyle(.secondary)
            } else {
                ForEach(restarts) { restart in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(restartReasonLabel(restart.reason)).font(.subheadline)
                            Spacer()
                            Text(restart.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            if let uptime = restart.uptimeSec {
                                Text(String(localized: "Up \(formatUptime(uptime))"))
                            }
                            if let fw = restart.firmwareVersion {
                                Text("v\(fw)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - MDB state change history (admin)

    private var mdbHistorySection: some View {
        Section(String(localized: "MDB State Changes")) {
            if isLoadingMdbLogs && mdbLogs.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if mdbLogs.isEmpty {
                Text(String(localized: "No state changes recorded.")).foregroundStyle(.secondary)
            } else {
                ForEach(mdbLogs) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            if let prev = entry.prevState {
                                Text("\(stateLabel(prev)) → \(stateLabel(entry.state))").font(.subheadline)
                            } else {
                                Text(String(localized: "Initial: \(stateLabel(entry.state))")).font(.subheadline)
                            }
                            Spacer()
                            Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if entry.lastCmd != nil || entry.polls != nil {
                            HStack(spacing: 6) {
                                if let cmd = entry.lastCmd { Text("Cmd: \(cmd)") }
                                if let polls = entry.polls { Text("\(polls) polls") }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Suppressed sales (auto-removed duplicates)

    @ViewBuilder
    private var suppressedSection: some View {
        Section {
            if detailViewModel.suppressedSales.isEmpty {
                Text(String(localized: "None — no duplicates auto-removed.")).foregroundStyle(.secondary)
            } else {
                let groups = groupSuppressedByDay(detailViewModel.suppressedSales)
                ForEach(groups, id: \.date) { group in
                    Section {
                        ForEach(group.rows) { sale in
                            SuppressedSaleRow(sale: sale, trays: detailViewModel.trays)
                                .contextMenu {
                                    if isAdmin {
                                        Button {
                                            rowToRestore = sale
                                        } label: {
                                            Label(String(localized: "Take up as sale"), systemImage: "checkmark.circle")
                                        }
                                    }
                                }
                                .restoreSaleDialog(for: sale, selection: $rowToRestore) { sale in
                                    Task { await detailViewModel.restoreSuppressed(sale.id) }
                                }
                        }
                    } header: {
                        Text(dayLabel(for: group.date))
                    }
                }
            }
        } header: {
            Text(String(localized: "Auto-Removed Duplicates"))
        } footer: {
            Text(String(localized: "Sales auto-dropped as suspected brownout re-reports."))
        }
    }

    private struct SuppressedDayGroup { let date: Date; let rows: [SuppressedSale] }

    private func groupSuppressedByDay(_ rows: [SuppressedSale]) -> [SuppressedDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.receivedAt) }
        return grouped.keys.sorted(by: >).map { date in
            SuppressedDayGroup(date: date, rows: grouped[date]!.sorted { $0.receivedAt > $1.receivedAt })
        }
    }

    private func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Loading

    private func loadRestarts() async {
        guard let embeddedId = embedded?.id else { return }
        isLoadingRestarts = true
        defer { isLoadingRestarts = false }
        do {
            restarts = try await SupabaseService.shared.client
                .from("device_restarts")
                .select("id, created_at, reason, uptime_sec, firmware_version, hw_reason")
                .eq("embedded_id", value: embeddedId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadStatusLog() async {
        guard let embeddedId = embedded?.id else { return }
        let since = Date().addingTimeInterval(-24 * 3600)
        do {
            statusLog = try await SupabaseService.shared.client
                .from("embedded_status_log")
                .select("status, prev_status, created_at")
                .eq("embedded_id", value: embeddedId.uuidString)
                .gte("created_at", value: since.ISO8601Format())
                .order("created_at", ascending: true)
                .execute()
                .value
        } catch is CancellationError {
        } catch {
            // The history is a nice-to-have: an older server without the table
            // must not put an error alert over the rest of the sheet.
            statusLog = []
        }
    }

    private func loadMdbLogs() async {
        guard let embeddedId = embedded?.id else { return }
        isLoadingMdbLogs = true
        defer { isLoadingMdbLogs = false }
        do {
            mdbLogs = try await SupabaseService.shared.client
                .from("mdb_log")
                .select("id, created_at, state, prev_state, addr, polls, chk_err, last_cmd")
                .eq("embedded_id", value: embeddedId.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Labels

    private func restartReasonLabel(_ reason: String) -> String {
        switch reason {
        case "mqtt_watchdog": return String(localized: "MQTT Watchdog")
        case "ota": return String(localized: "OTA Update")
        case "config": return String(localized: "Config Change")
        case "provision": return String(localized: "Provisioning")
        case "factory_reset": return String(localized: "Factory Reset")
        case "power_on": return String(localized: "Power On")
        case "panic": return String(localized: "Panic")
        case "brownout": return String(localized: "Brownout")
        case "watchdog": return String(localized: "HW Watchdog")
        case "unknown": return String(localized: "Unknown")
        // Show anything the firmware invents verbatim rather than hiding it
        // behind "Unknown" — same fallback the web uses.
        default: return reason
        }
    }

    private func stateLabel(_ state: String?) -> String {
        state?.capitalized ?? String(localized: "Unknown")
    }

    /// Mirrors the web's `formatUptime()` (`useDeviceRestarts.ts`) exactly, so
    /// the same device never shows two different runtimes across clients.
    private func formatUptime(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        if hours < 24 { return "\(hours)h \(minutes)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }
}
