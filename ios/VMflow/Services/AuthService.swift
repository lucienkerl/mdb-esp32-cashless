import Foundation
import Supabase
import Combine

/// Manages authentication state and user session via Supabase Auth.
/// Published properties drive the app's auth-dependent UI.
@MainActor
final class AuthService: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    @Published var organization: Organization?
    @Published var role: OrganizationRole?
    @Published var error: String?

    /// Set 5 seconds into a session restore that hasn't resolved yet (e.g. the
    /// configured server is unreachable). The launch screen uses this to offer
    /// a way out to the server picker — it does NOT stop the restore attempt,
    /// which may still succeed.
    @Published private(set) var sessionRestoreTimedOut = false

    /// Signed-in user's profile, mirrored from the auth session so the UI can
    /// show and edit the name that ends up in refill/activity logs.
    @Published var firstName = ""
    @Published var lastName = ""
    @Published var userEmail: String?

    /// Full name if set, otherwise the email — same fallback the activity-log
    /// writers use for `_user_display`.
    var displayName: String {
        let full = [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return full.isEmpty ? (userEmail ?? "") : full
    }

    private var client: SupabaseClient { SupabaseService.shared.client }
    private var authStateTask: Task<Void, Never>?

    /// Write guard for the in-flight session-restore path. Set by
    /// `cancelSessionRestore()`; checked by every write `checkSession()`
    /// would otherwise make so a `client.auth.session` call that resolves
    /// after the user has bailed to the login screen can't yank them back
    /// out mid-typing. Scoped to session restore only — `login()` never
    /// consults it, so a deliberate sign-in afterwards works normally.
    private var restoreCancelled = false

    init() {
        startAuthListener()
    }

    /// (Re)start the auth state change listener on the current Supabase client.
    /// Called on init and after server reconfiguration. Resets the
    /// session-restore write guard and timeout flag so a fresh restore
    /// attempt (e.g. after picking a different server) starts clean and the
    /// "server not responding" button doesn't linger from the previous
    /// attempt.
    func restartAuthListener() {
        authStateTask?.cancel()
        restoreCancelled = false
        sessionRestoreTimedOut = false
        startAuthListener()
    }

    private func startAuthListener() {
        authStateTask = Task { [weak self] in
            guard let self else { return }
            await self.checkSession()
            for await (event, _) in self.client.auth.authStateChanges {
                switch event {
                case .signedIn:
                    self.isAuthenticated = true
                    await self.fetchOrganization()
                    await self.loadProfile()
                    Task { await self.syncLocaleToServer() }
                case .signedOut:
                    self.isAuthenticated = false
                    self.organization = nil
                    self.role = nil
                    self.firstName = ""
                    self.lastName = ""
                    self.userEmail = nil
                default:
                    break
                }
                self.isLoading = false
            }
        }
    }

    deinit {
        authStateTask?.cancel()
    }

    // MARK: - Session

    /// Check for an existing session on app launch.
    ///
    /// Starts a 5-second side timer: if the restore is still in flight when
    /// it fires, it flips `sessionRestoreTimedOut` and nothing else — the
    /// spinner keeps running because the connection may still succeed. Every
    /// write below checks `restoreCancelled` first so a session result that
    /// arrives after the user has cancelled out to the login screen can't
    /// silently reinstate them.
    func checkSession() async {
        isLoading = true

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled, !self.restoreCancelled else { return }
            self.sessionRestoreTimedOut = true
        }
        defer { timeoutTask.cancel() }

        do {
            let session = try await client.auth.session
            guard !restoreCancelled else { return }
            isAuthenticated = true
            _ = session
            await fetchOrganization()
            guard !restoreCancelled else { return }
            await loadProfile()
            guard !restoreCancelled else { return }
            Task { await self.syncLocaleToServer() }
        } catch {
            guard !restoreCancelled else { return }
            isAuthenticated = false
        }
        guard !restoreCancelled else { return }
        isLoading = false
    }

    /// Called from the launch screen's "server not responding" offer. Bails
    /// the user out to the ordinary login screen (which carries the server
    /// picker) without waiting for the in-flight `client.auth.session` call
    /// to resolve. That call keeps running in the background — the guard
    /// above ensures its eventual result (or the auth listener's handling of
    /// it) writes nothing once `restoreCancelled` is set here.
    func cancelSessionRestore() {
        authStateTask?.cancel()
        isAuthenticated = false
        isLoading = false
        restoreCancelled = true
    }

    // MARK: - Login

    /// Sign in with email and password.
    func login(email: String, password: String) async {
        error = nil
        isLoading = true
        do {
            try await client.auth.signIn(email: email, password: password)
            isAuthenticated = true
            await fetchOrganization()
            await loadProfile()
            Task { await self.syncLocaleToServer() }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Register

    /// Create a new account with email and password.
    func register(email: String, password: String, firstName: String, lastName: String) async {
        error = nil
        isLoading = true
        do {
            try await client.auth.signUp(
                email: email,
                password: password,
                data: [
                    "first_name": .string(firstName),
                    "last_name": .string(lastName)
                ]
            )
            isAuthenticated = true
            await fetchOrganization()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    // MARK: - Logout

    /// Sign out and clear state.
    func logout() async {
        do {
            try await client.auth.signOut()
        } catch {
            // Ignore sign-out errors — clear local state regardless
        }
        isAuthenticated = false
        organization = nil
        role = nil
    }

    // MARK: - Profile

    /// Reads the signed-in user's name from the auth session metadata. Falls
    /// back to `public.users` for accounts created before the metadata was
    /// written (or renamed from the web app, which only writes the table).
    func loadProfile() async {
        do {
            let user = try await client.auth.session.user
            userEmail = user.email
            firstName = user.userMetadata["first_name"]?.stringValue ?? ""
            lastName = user.userMetadata["last_name"]?.stringValue ?? ""

            if firstName.isEmpty && lastName.isEmpty {
                struct Row: Decodable {
                    let firstName: String?
                    let lastName: String?
                    enum CodingKeys: String, CodingKey {
                        case firstName = "first_name"
                        case lastName = "last_name"
                    }
                }
                let rows: [Row] = try await client
                    .from("users")
                    .select("first_name, last_name")
                    .eq("id", value: user.id.uuidString)
                    .limit(1)
                    .execute()
                    .value
                firstName = rows.first?.firstName ?? ""
                lastName = rows.first?.lastName ?? ""
            }
        } catch {
            print("[AuthService] loadProfile failed: \(error)")
        }
    }

    /// Renames the signed-in user. Writes both places the app reads names from:
    /// the auth metadata (used at write time by the refill/cash-book activity
    /// log) and `public.users` (joined when rendering historical entries).
    /// Returns an error message on failure, nil on success.
    func updateProfileName(firstName newFirst: String, lastName newLast: String) async -> String? {
        let first = newFirst.trimmingCharacters(in: .whitespaces)
        let last = newLast.trimmingCharacters(in: .whitespaces)
        guard !first.isEmpty || !last.isEmpty else {
            return String(localized: "Enter a first or last name.")
        }

        do {
            let userId = try await client.auth.session.user.id

            _ = try await client.auth.update(
                user: UserAttributes(data: [
                    "first_name": .string(first),
                    "last_name": .string(last),
                ])
            )

            struct Update: Encodable {
                let firstName: String
                let lastName: String
                enum CodingKeys: String, CodingKey {
                    case firstName = "first_name"
                    case lastName = "last_name"
                }
            }
            try await client
                .from("users")
                .update(Update(firstName: first, lastName: last))
                .eq("id", value: userId.uuidString)
                .execute()

            firstName = first
            lastName = last
            return nil
        } catch {
            print("[AuthService] updateProfileName failed: \(error)")
            return error.localizedDescription
        }
    }

    // MARK: - Locale sync

    /// Read the device's primary language code and persist it to
    /// `public.users.locale` (clamped to "en" / "de"). Idempotent: caches
    /// the last-synced value in UserDefaults and skips the write if
    /// unchanged. Best-effort — failures log but never surface to the user.
    ///
    /// Call on: successful login, scene phase `.active`, and on the
    /// `NSLocale.currentLocaleDidChangeNotification`.
    func syncLocaleToServer() async {
        let deviceCode = Locale.current.language.languageCode?.identifier ?? "en"
        let locale = (deviceCode.lowercased() == "de") ? "de" : "en"

        let cacheKey = "vmflow-last-synced-locale"
        if UserDefaults.standard.string(forKey: cacheKey) == locale {
            return
        }

        do {
            let userId = try await client.auth.session.user.id
            try await client.from("users")
                .update(["locale": locale])
                .eq("id", value: userId)
                .execute()
            UserDefaults.standard.set(locale, forKey: cacheKey)
            print("[Locale] Synced user locale to \(locale)")
        } catch {
            print("[Locale] Sync failed (best-effort): \(error)")
        }
    }

    // MARK: - Organization

    /// Fetch the user's organization via the `get-my-organization` edge function.
    func fetchOrganization() async {
        do {
            print("[AuthService] Fetching organization from \(SupabaseService.shared.supabaseURL)/functions/v1/get-my-organization")
            let response: OrganizationResponse = try await client.functions.invoke(
                "get-my-organization",
                options: .init(method: .get)
            )
            print("[AuthService] Response: org=\(String(describing: response.organization?.name)), role=\(String(describing: response.role))")
            organization = response.organization
            if let roleString = response.role {
                role = OrganizationRole(rawValue: roleString)
            }
        } catch {
            print("[AuthService] fetchOrganization error: \(error)")
            organization = nil
            role = nil
        }
    }

    /// The current access token for API calls.
    var accessToken: String? {
        get async {
            try? await client.auth.session.accessToken
        }
    }

    // MARK: - Account Deletion

    /// Outcome of a `delete-account` call (Apple Guideline 5.1.1(v)).
    enum DeleteAccountOutcome {
        case success(companyDeleted: Bool)
        case companyNameMismatch
        case failure(String)
    }

    /// Calls the `delete-account` edge function.
    ///
    /// Deliberately does NOT duplicate the "sole admin" rule client-side: the
    /// server is the single source of truth for whether the caller must type
    /// the company name. A 400 `company_name_mismatch` response is what
    /// drives `DeleteAccountSheet`'s second stage — the client only reacts to
    /// that response, it never decides on its own.
    func deleteAccount(confirmCompanyName: String?) async -> DeleteAccountOutcome {
        struct RequestBody: Encodable {
            let confirm_company_name: String?
        }
        struct SuccessResponse: Decodable {
            let deleted: Bool
            let company_deleted: Bool
        }
        struct ErrorResponse: Decodable {
            let error: String
        }

        do {
            let response: SuccessResponse = try await client.functions.invoke(
                "delete-account",
                options: .init(method: .post, body: RequestBody(confirm_company_name: confirmCompanyName))
            )
            return .success(companyDeleted: response.company_deleted)
        } catch FunctionsError.httpError(let code, let data) {
            let serverError = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if code == 400 && serverError?.error == "company_name_mismatch" {
                return .companyNameMismatch
            }
            return .failure(serverError?.error ?? "Account deletion failed (\(code)).")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
