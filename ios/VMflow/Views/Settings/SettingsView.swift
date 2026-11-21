import SwiftUI

/// App settings with notification preferences, deal search, and account management.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthService
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var deals = DealsViewModel()
    @State private var isSendingTest = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteAccount = false
    @State private var showRenameProfile = false
    @FocusState private var zipFieldFocused: Bool

    var body: some View {
        List {
            // MARK: - Push Notifications Section
            Section {
                pushToggle
                if notifications.isEnabled {
                    testButton
                }
            } header: {
                Label("Push Notifications", systemImage: "bell.fill")
            } footer: {
                if notifications.permissionStatus == .denied {
                    Text("Notifications are disabled in system settings. Open Settings to enable them.")
                        .foregroundStyle(.orange)
                }
            }

            // MARK: - Notification Matrix (event × channel)
            Section {
                notificationMatrix
            } header: {
                HStack {
                    Label("Notifications", systemImage: "slider.horizontal.3")
                    Spacer()
                    ForEach(NotificationService.channelKeys, id: \.self) { channel in
                        Image(systemName: Self.channelIcon(channel))
                            .frame(width: 44)
                            .accessibilityLabel(Self.channelLabel(channel))
                    }
                }
            } footer: {
                notificationMatrixFooter
            }

            // MARK: - Deals Section
            Section {
                Toggle(isOn: Binding(
                    get: { deals.dealsEnabled },
                    set: { newValue in
                        deals.dealsEnabled = newValue
                        Task { await deals.saveSettings() }
                    }
                )) {
                    HStack(spacing: 12) {
                        Image(systemName: "tag.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 28)
                        Text("Enable Deal Search")
                    }
                }

                if deals.dealsEnabled {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 28)

                        Text("ZIP Code")

                        Spacer()

                        TextField("e.g. 60487", text: $deals.dealsZipCode)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 120)
                            .focused($zipFieldFocused)
                            .onSubmit {
                                Task { await deals.saveSettings() }
                            }
                            .toolbar {
                                // .numberPad has no Return key, so onSubmit above can
                                // never fire — this is the only way to confirm entry.
                                ToolbarItemGroup(placement: .keyboard) {
                                    if zipFieldFocused {
                                        Spacer()
                                        Button(String(localized: "Done")) {
                                            zipFieldFocused = false
                                            Task { await deals.saveSettings() }
                                        }
                                    }
                                }
                            }
                    }
                }
            } header: {
                Label("Deals", systemImage: "tag.fill")
            } footer: {
                Text("Automatically find retailer offers matching your products based on your ZIP code.")
            }

            // MARK: - Account Section
            Section {
                // Same rename entry point as the dashboard profile menu.
                Button {
                    showRenameProfile = true
                } label: {
                    HStack {
                        Text("Name").foregroundStyle(.primary)
                        Spacer()
                        Text(auth.displayName)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.quaternary)
                    }
                }
                if let org = auth.organization {
                    HStack {
                        Text("Organization")
                        Spacer()
                        Text(org.name)
                            .foregroundStyle(.secondary)
                    }
                }
                if let role = auth.role {
                    HStack {
                        Text("Role")
                        Spacer()
                        Text(role.rawValue.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Account", systemImage: "person.fill")
            }

            // MARK: - Sign Out
            Section {
                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Sign Out")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            }

            // MARK: - Delete Account
            Section {
                Button(role: .destructive) {
                    showDeleteAccount = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Delete Account")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
            } footer: {
                Text("Permanently delete your account and, if you are the last admin, your organization's data.")
            }

            // MARK: - About Section
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("About", systemImage: "info.circle")
            }
        }
        .navigationTitle("Settings")
        .task {
            await notifications.checkPermissionStatus()
            await notifications.fetchPreferences()
            await deals.loadSettings()
        }
        .alert("Sign Out", isPresented: $showSignOutConfirm) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await notifications.cleanupOnLogout()
                    await auth.logout()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Error", isPresented: .init(
            get: { notifications.error != nil },
            set: { if !$0 { notifications.error = nil } }
        )) {
            Button("OK") { notifications.error = nil }
        } message: {
            Text(notifications.error ?? "")
        }
        .sheet(isPresented: $showDeleteAccount) {
            DeleteAccountSheet()
        }
        .sheet(isPresented: $showRenameProfile) {
            ProfileNameSheet()
                .environmentObject(auth)
        }
    }

    // MARK: - Push Toggle

    private var pushToggle: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Notifications")
                    .font(.body)
                if notifications.isRegistering {
                    Text("Registering...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if notifications.permissionStatus == .denied {
                // Permission denied — link to Settings
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { notifications.isEnabled },
                    set: { newValue in
                        Task {
                            if newValue {
                                let granted = await notifications.requestPermission()
                                if granted {
                                    await notifications.fetchPreferences()
                                }
                            } else {
                                await notifications.unregisterDevice()
                            }
                        }
                    }
                ))
                .labelsHidden()
            }
        }
    }

    // MARK: - Notification Matrix

    static func channelIcon(_ channel: String) -> String {
        channel == "email" ? "envelope.fill" : "bell.fill"
    }

    static func channelLabel(_ channel: String) -> String {
        channel == "email" ? String(localized: "Email") : String(localized: "Push")
    }

    /// One row per event type, one round toggle per channel (push, email).
    /// Account-wide, so it is shown whether or not push is on for this device.
    private var notificationMatrix: some View {
        ForEach(NotificationService.notificationTypes) { type in
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.body)
                    .foregroundStyle(notifications.isTypeEnabled(type.key) ? .orange : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.label)
                        .font(.body)
                    Text(type.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                ForEach(NotificationService.channelKeys, id: \.self) { channel in
                    channelToggle(type: type, channel: channel)
                }
            }
        }
    }

    private func channelToggle(type: NotificationType, channel: String) -> some View {
        let on = notifications.isEnabled(type.key, channel: channel)
        let available = notifications.channelInfo(channel)?.available ?? (channel == "push")
        return Button {
            Task { await notifications.setEnabled(type.key, channel: channel, enabled: !on) }
        } label: {
            Image(systemName: Self.channelIcon(channel))
                .font(.subheadline)
                .foregroundStyle(on ? Color.white : Color.secondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(on ? Color.accentColor : Color(.tertiarySystemFill)))
                .frame(width: 44)
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.35)
        .accessibilityLabel("\(type.label), \(Self.channelLabel(channel))")
        .accessibilityValue(on ? String(localized: "On") : String(localized: "Off"))
        .accessibilityAddTraits(.isToggle)
    }

    @ViewBuilder
    private var notificationMatrixFooter: some View {
        let email = notifications.channelInfo("email")
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose for each event whether it arrives as push, email or both. Applies to all your devices.")
            if let email, email.configured == false {
                Text("Email is not set up on this server yet.")
            } else if let address = email?.address, !address.isEmpty {
                Text("Emails go to \(address)")
            }
        }
    }

    // MARK: - Test Button

    private var testButton: some View {
        Button {
            Task {
                isSendingTest = true
                await notifications.sendTestNotification()
                isSendingTest = false
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .font(.body)
                    .foregroundStyle(.green)
                    .frame(width: 28)

                Text("Send Test Notification")

                Spacer()

                if isSendingTest {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .disabled(isSendingTest)
    }
}

/// Converts the stamped short-version string ("1.0.260727") into the
/// human-facing display form ("1.0.7.27"). Falls back to the raw input if the
/// last component is not a 6-digit YYMMDD date.
enum AppVersion {
    static func display(from shortVersion: String) -> String {
        let parts = shortVersion.split(separator: ".").map(String.init)
        guard let last = parts.last, last.count == 6, Int(last) != nil else {
            return shortVersion
        }
        let base = parts.dropLast().joined(separator: ".")
        let mm = Int(last.dropFirst(2).prefix(2)) ?? 0
        let dd = Int(last.suffix(2)) ?? 0
        return "\(base).\(mm).\(dd)"
    }

    static var current: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return display(from: short)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(AuthService())
    }
}
