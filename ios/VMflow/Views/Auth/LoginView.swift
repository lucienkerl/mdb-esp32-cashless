import SwiftUI

/// Login screen with email/password fields and VMflow branding.
struct LoginView: View {
    @EnvironmentObject var auth: AuthService

    @State private var email = ""
    @State private var password = ""
    @ObservedObject var serverStore = ServerStore.shared
    @State private var showServerSheet = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case email, password
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Branding
                VStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(.top, 60)

                    Text("VMflow")
                        .font(.largeTitle.bold())

                    Text("Vending Machine Management")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Form
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Email")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        // `.username`, not `.emailAddress`: only the username
                        // hint pairs this field with the password below, so
                        // iCloud Keychain / 1Password fill both and offer to
                        // save the login (webcredentials:app.kerl-handel.de).
                        TextField("you@example.com", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .email)
                            .padding(12)
                            .background(.fill.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .padding(12)
                            .background(.fill.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 24)

                // Error
                if let error = auth.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                // Login Button
                Button {
                    focusedField = nil
                    Task {
                        await auth.login(email: email.trimmingCharacters(in: .whitespaces), password: password)
                    }
                } label: {
                    if auth.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Text("Sign In")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(email.isEmpty || password.isEmpty || auth.isLoading)
                .padding(.horizontal, 24)

                // Register Link
                NavigationLink {
                    RegisterView()
                } label: {
                    HStack(spacing: 4) {
                        Text("Don't have an account?")
                            .foregroundStyle(.secondary)
                        Text("Sign Up")
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }

                // Server indicator
                Button {
                    showServerSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Connected to", comment: "Server indicator prefix on login screen")
                            .foregroundStyle(.secondary)
                        Text(serverStore.selectedServer.name)
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
                .sheet(isPresented: $showServerSheet) {
                    ServerSelectionSheet()
                }
            }
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationBarHidden(true)
    }
}

#Preview {
    NavigationStack {
        LoginView()
            .environmentObject(AuthService())
    }
}
