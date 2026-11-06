import SwiftUI

/// Registration form with first name, last name, email, and password.
struct RegisterView: View {
    @EnvironmentObject var auth: AuthService
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var serverStore = ServerStore.shared

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case firstName, lastName, email, password, confirmPassword
    }

    private var isFormValid: Bool {
        !firstName.isEmpty &&
        !lastName.isEmpty &&
        !email.isEmpty &&
        password.count >= 6 &&
        password == confirmPassword
    }

    private var passwordMismatch: Bool {
        !confirmPassword.isEmpty && password != confirmPassword
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Text("Create Account")
                        .font(.title.bold())
                    Text("Join VMflow to manage your vending machines")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                // Form
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        formField("First Name", text: $firstName, field: .firstName) {
                            TextField("First", text: $firstName)
                                .textContentType(.givenName)
                                .focused($focusedField, equals: .firstName)
                        }

                        formField("Last Name", text: $lastName, field: .lastName) {
                            TextField("Last", text: $lastName)
                                .textContentType(.familyName)
                                .focused($focusedField, equals: .lastName)
                        }
                    }

                    formField("Email", text: $email, field: .email) {
                        // `.username` so the strong password suggested for the
                        // `.newPassword` fields is saved under this email.
                        TextField("you@example.com", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .email)
                    }

                    formField("Password", text: $password, field: .password) {
                        SecureField("Min. 6 characters", text: $password)
                            .textContentType(.newPassword)
                            .focused($focusedField, equals: .password)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Confirm Password")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        SecureField("Confirm", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .focused($focusedField, equals: .confirmPassword)
                            .padding(12)
                            .background(.fill.tertiary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        if passwordMismatch {
                            Text("Passwords don't match")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
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

                // Register Button
                Button {
                    focusedField = nil
                    Task {
                        await auth.register(
                            email: email.trimmingCharacters(in: .whitespaces),
                            password: password,
                            firstName: firstName.trimmingCharacters(in: .whitespaces),
                            lastName: lastName.trimmingCharacters(in: .whitespaces)
                        )
                    }
                } label: {
                    if auth.isLoading {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    } else {
                        Text("Create Account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isFormValid || auth.isLoading)
                .padding(.horizontal, 24)

                // Server indicator
                HStack(spacing: 4) {
                    Text("Connected to", comment: "Server indicator prefix on register screen")
                        .foregroundStyle(.secondary)
                    Text(serverStore.selectedServer.name)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Sign Up")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func formField<Content: View>(
        _ label: LocalizedStringKey,
        text: Binding<String>,
        field: Field,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
                .padding(12)
                .background(.fill.tertiary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

#Preview {
    NavigationStack {
        RegisterView()
            .environmentObject(AuthService())
    }
}
