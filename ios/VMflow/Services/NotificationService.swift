import Foundation
import UserNotifications
import UIKit
import Supabase

// MARK: - Models

/// One cell of the notification matrix (event type × channel), table
/// `notification_settings`. A missing row means the channel's default:
/// push on, every other channel off (opt-in) — same rule as the web
/// (`app/lib/notificationSettings.ts`) and the backend.
struct NotificationSetting: Codable, Equatable {
    let notificationType: String
    let channel: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case notificationType = "notification_type"
        case channel
        case enabled
    }
}

/// A delivery channel of the matrix, with what the server can do.
struct NotificationChannelInfo: Codable, Identifiable, Equatable {
    let key: String
    let available: Bool
    var configured: Bool?
    var address: String?

    var id: String { key }
}

struct NotificationType: Identifiable {
    let key: String
    let label: String
    let description: String
    let icon: String

    var id: String { key }
}

// MARK: - Service

/// Manages push notification permissions, device registration, and the
/// per-event, per-channel notification settings (push / email).
@MainActor
final class NotificationService: ObservableObject {
    static let shared = NotificationService()

    // MARK: - Published State

    @Published var isEnabled: Bool = false
    @Published var permissionStatus: UNAuthorizationStatus = .notDetermined
    @Published var settings: [NotificationSetting] = []
    @Published var channels: [NotificationChannelInfo] = NotificationService.channelKeys.map {
        NotificationChannelInfo(key: $0, available: $0 == "push")
    }
    @Published var deviceToken: String?
    @Published var isRegistering: Bool = false
    @Published var error: String?

    /// Open inbox count (problems + feedback + wishes with status='new').
    /// Drives the app icon badge AND the badge on the Inbox tab.
    /// Refreshed on app foreground, after Inbox actions, and on push receive.
    @Published var openInboxCount: Int = 0

    /// Set when a notification tap should deep-link into a specific tab.
    /// `MainTabView` observes this and resets it after consuming the value
    /// so back-stack navigation behaves naturally.
    @Published var pendingDeepLink: DeepLink?

    /// Deep-link targets we currently know how to route to from a push tap.
    enum DeepLink: Equatable {
        case inbox
    }

    /// Matrix columns, in order (matches web UI).
    static let channelKeys = ["push", "email"]

    /// Matrix rows, in order (matches web UI).
    static let notificationTypes: [NotificationType] = [
        NotificationType(
            key: "sale",
            label: String(localized: "Sale Notifications"),
            description: String(localized: "Get notified for every vending machine sale"),
            icon: "cart.fill"
        ),
        NotificationType(
            key: "low_stock",
            label: String(localized: "Low Stock Alerts"),
            description: String(localized: "Get notified when a product drops below the refill threshold"),
            icon: "exclamationmark.triangle.fill"
        ),
        NotificationType(
            key: "machine_offline",
            label: String(localized: "Machine Offline"),
            description: String(localized: "A machine has not been reachable for a few minutes"),
            icon: "wifi.slash"
        ),
        NotificationType(
            key: "machine_online",
            label: String(localized: "Machine Back Online"),
            description: String(localized: "A machine you were alerted about is reachable again"),
            icon: "wifi"
        ),
        NotificationType(
            key: "inbox",
            label: String(localized: "Customer Inbox"),
            description: String(localized: "Get notified when a customer reports a problem, leaves feedback, or submits a product wish"),
            icon: "tray.full.fill"
        ),
        NotificationType(
            key: "new_deals",
            label: String(localized: "New Deals"),
            description: String(localized: "Once a day, when new retailer offers match your products"),
            icon: "tag.fill"
        ),
    ]

    private var client: SupabaseClient { SupabaseService.shared.client }
    /// Key for persisting the last registered token to detect changes.
    private let tokenKey = "apns-device-token"

    private init() {}

    // MARK: - Permission

    /// Check current notification permission status without prompting.
    func checkPermissionStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permissionStatus = settings.authorizationStatus
        isEnabled = settings.authorizationStatus == .authorized
    }

    /// Request notification permission and register for remote notifications if granted.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await checkPermissionStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    // MARK: - Device Token

    /// Called by AppDelegate when APNs registration succeeds.
    func handleDeviceToken(_ token: String) {
        let previousToken = UserDefaults.standard.string(forKey: tokenKey)
        self.deviceToken = token

        // Only re-register if token changed or never registered
        if token != previousToken {
            Task { await registerWithBackend(token: token) }
        }
    }

    /// Called by AppDelegate when APNs registration fails.
    func handleRegistrationError(_ error: Error) {
        print("[Push] Registration error: \(error)")
        // Don't show error for simulator (push not supported)
        #if !targetEnvironment(simulator)
        self.error = String(localized: "Push registration failed")
        #endif
    }

    /// Register this device's APNs token with the backend.
    private func registerWithBackend(token: String) async {
        isRegistering = true
        defer { isRegistering = false }

        do {
            struct RegisterBody: Encodable {
                let fcm_token: String
                let platform: String
                let bundle_id: String?
            }

            try await client.functions.invoke(
                "register-push",
                options: .init(body: RegisterBody(
                    fcm_token: token,
                    platform: "ios",
                    bundle_id: Bundle.main.bundleIdentifier
                ))
            )

            UserDefaults.standard.set(token, forKey: tokenKey)
            print("[Push] Registered device token with backend")
        } catch {
            print("[Push] Backend registration failed: \(error)")
            self.error = String(localized: "Failed to register for push notifications")
        }
    }

    /// Unregister this device from push notifications.
    /// Best-effort: if the user is already logged out (401), we still clean up locally.
    /// The server-side subscription becomes stale but is auto-cleaned on next failed push.
    func unregisterDevice() async {
        guard let token = deviceToken ?? UserDefaults.standard.string(forKey: tokenKey) else { return }

        // Only attempt server-side removal if we have a valid session
        if let _ = try? await client.auth.session {
            do {
                struct UnregisterBody: Encodable {
                    let fcm_token: String
                }

                try await client.functions.invoke(
                    "register-push",
                    options: .init(method: .delete, body: UnregisterBody(fcm_token: token))
                )
                print("[Push] Unregistered device from server")
            } catch {
                // 401 is expected during logout — ignore silently
                print("[Push] Server unregister skipped (session likely expired)")
            }
        }

        // Always clean up locally
        UserDefaults.standard.removeObject(forKey: tokenKey)
        deviceToken = nil
        isEnabled = false
    }

    // MARK: - Notification Settings (event type × channel)

    /// Fetch the user's notification matrix and which channels the server can deliver.
    func fetchPreferences() async {
        do {
            settings = try await client
                .from("notification_settings")
                .select("notification_type, channel, enabled")
                .execute()
                .value
        } catch is CancellationError {
        } catch {
            print("[Push] Failed to fetch notification settings: \(error)")
        }

        struct ChannelsResponse: Decodable { let channels: [NotificationChannelInfo] }
        do {
            let response: ChannelsResponse = try await client.functions.invoke(
                "notification-channels",
                options: .init(method: .get)
            )
            channels = Self.channelKeys.map { key in
                response.channels.first { $0.key == key } ?? NotificationChannelInfo(key: key, available: false)
            }
        } catch is CancellationError {
        } catch {
            print("[Push] Failed to fetch notification channels: \(error)")
        }
    }

    /// Default for a cell without a row: push on, every other channel opt-in.
    static func channelDefault(_ channel: String) -> Bool { channel == "push" }

    /// Whether `type` is on for `channel`.
    func isEnabled(_ type: String, channel: String) -> Bool {
        settings.first { $0.notificationType == type && $0.channel == channel }?.enabled
            ?? Self.channelDefault(channel)
    }

    /// Whether `type` is on for any channel (row icon tint).
    func isTypeEnabled(_ type: String) -> Bool {
        Self.channelKeys.contains { isEnabled(type, channel: $0) }
    }

    func channelInfo(_ key: String) -> NotificationChannelInfo? {
        channels.first { $0.key == key }
    }

    /// Switch one cell. Optimistic; rolled back when the write fails.
    func setEnabled(_ type: String, channel: String, enabled: Bool) async {
        let before = settings
        settings.removeAll { $0.notificationType == type && $0.channel == channel }
        settings.append(NotificationSetting(notificationType: type, channel: channel, enabled: enabled))
        do {
            let userId = try await client.auth.session.user.id
            try await client
                .from("notification_settings")
                .upsert(
                    [
                        "user_id": AnyJSON.string(userId.uuidString),
                        "notification_type": AnyJSON.string(type),
                        "channel": AnyJSON.string(channel),
                        "enabled": AnyJSON.bool(enabled),
                        "updated_at": AnyJSON.string(ISO8601DateFormatter().string(from: Date())),
                    ],
                    onConflict: "user_id,notification_type,channel"
                )
                .execute()
        } catch {
            settings = before
            print("[Push] Failed to save notification setting: \(error)")
            self.error = error.localizedDescription
        }
    }

    // MARK: - Test Notification

    /// Send a test push notification to this device via the backend.
    func sendTestNotification() async {
        do {
            try await client.functions.invoke(
                "test-push",
                options: .init(method: .post)
            )
        } catch {
            self.error = String(localized: "Test notification failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Notification Tap Handling

    /// Handle taps on received notifications. Routes to the right tab via
    /// `pendingDeepLink` which `MainTabView` observes.
    func handleNotificationTap(type: String, userInfo: [AnyHashable: Any]) {
        print("[Push] Handle tap: type=\(type), data=\(userInfo)")
        if type == "inbox" {
            pendingDeepLink = .inbox
        }
    }

    // MARK: - Badge

    /// Recompute the open inbox count from Supabase and apply it to the app
    /// icon badge. Call on app foreground, after marking items as reviewed/
    /// dismissed, and after pushes are received in foreground.
    ///
    /// Reads `machine_feedback` AND `product_wishes` and sums entries with
    /// status='new'. Failures are silent — the badge keeps its previous
    /// value rather than dropping to 0 spuriously.
    func refreshBadge() async {
        do {
            // Two parallel HEAD count queries via PostgREST. RLS scopes them
            // to the current user's company automatically.
            async let feedbackCount: Int = countOpen(table: "machine_feedback")
            async let wishCount: Int = countOpen(table: "product_wishes")

            let total = try await (feedbackCount + wishCount)
            openInboxCount = total
            await applyBadgeToAppIcon(total)
        } catch is CancellationError {
            // ignore
        } catch {
            print("[Inbox] refreshBadge failed: \(error)")
        }
    }

    private func countOpen(table: String) async throws -> Int {
        let response = try await client
            .from(table)
            .select("id", head: true, count: .exact)
            .eq("status", value: "new")
            .execute()
        return response.count ?? 0
    }

    /// Set the iOS home-screen icon badge. Uses the iOS 17+ API when
    /// available and falls back to the deprecated property otherwise.
    private func applyBadgeToAppIcon(_ count: Int) async {
        if #available(iOS 17.0, *) {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        } else {
            await MainActor.run {
                UIApplication.shared.applicationIconBadgeNumber = count
            }
        }
    }

    // MARK: - Lifecycle

    /// Call after successful login to set up push notifications.
    func setupAfterLogin() async {
        await checkPermissionStatus()

        if permissionStatus == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }

        await fetchPreferences()
        await refreshBadge()
    }

    /// Call on logout to clean up.
    func cleanupOnLogout() async {
        await unregisterDevice()
        settings = []
        openInboxCount = 0
        await applyBadgeToAppIcon(0)
    }
}
