import Observation
import SwiftUI

@MainActor
@Observable
final class AuthModel {
    enum Provider: Equatable { case apple, google, email }
    var inProgress: Provider?
    var errorMessage: String?
    var errorTrigger = 0

    func run(_ provider: Provider, _ operation: @escaping () async throws -> Void) async {
        guard inProgress == nil else { return }
        inProgress = provider
        errorMessage = nil
        defer { inProgress = nil }
        do {
            try await operation()
        } catch let error as AuthFlowError where error.isCancellation {
            // Cancellation is the user's choice: no error message, no haptic.
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            errorTrigger += 1
        }
    }
}

struct AuthView: View {
    enum Presentation { case root, sheet }
    let presentation: Presentation

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var model = AuthModel()
    @State private var emailMode: EmailAuthView.Mode?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if presentation == .sheet {
                    HStack {
                        Spacer()
                        FloatingGlassIconButton(systemName: "xmark", accessibilityLabel: Text("Close")) {
                            session.pendingIntent = nil
                            dismiss()
                        }
                    }
                }
                Spacer(minLength: presentation == .root ? 40 : 12)
                header
                    .padding(.bottom, 36)
                if let notice = session.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.zunoPrimary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                        .padding(.bottom, 16)
                }
                providers
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: .systemRed))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 14)
                        .accessibilityIdentifier("auth.error")
                }
                footer
                    .padding(.top, 28)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .readableWidth(460)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(ZunoColor.background.ignoresSafeArea())
        .sensoryFeedback(.error, trigger: model.errorTrigger)
        .sheet(item: $emailMode) { mode in
            EmailAuthView(initialMode: mode)
        }
        .zunoContainer("auth.view")
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZunoWordmark(size: 56)
            Text("Welcome to Zuno")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.zunoPrimary)
            Text(presentation == .sheet
                 ? "Sign in to register, buy tickets and keep them in one place."
                 : "Discover meetups, hackathons, workshops and cultural evenings across Sri Lanka.")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.zunoSecondary)
        }
    }

    private var providers: some View {
        VStack(spacing: 12) {
            AppleSignInButton(type: .continue, style: .white) {
                Task {
                    await model.run(.apple) {
                        let credential = try await environment.appleAuthorizer.authorize(requestNameAndEmail: true)
                        try await environment.auth.signInWithApple(credential)
                        session.rememberAppleUser(credential.userIdentifier)
                    }
                }
            }
            .frame(height: 54)
            .disabled(model.inProgress != nil)
            .overlay { if model.inProgress == .apple { ProgressView().tint(.black) } }
            .accessibilityLabel(Text("Continue with Apple"))

            GoogleSignInButton {
                Task { await model.run(.google) { try await environment.auth.signInWithGoogle() } }
            }
            .disabled(model.inProgress != nil)
            .overlay { if model.inProgress == .google { ProgressView().tint(.black) } }

            Button {
                emailMode = .signIn
            } label: {
                Label("Continue with email", systemImage: "envelope")
            }
            .buttonStyle(SecondaryCapsuleButtonStyle())
            .disabled(model.inProgress != nil)
            .accessibilityIdentifier("auth.email")

            HStack(spacing: 18) {
                Button("Create account") { emailMode = .signUp }
                    .accessibilityIdentifier("auth.createAccount")
                Text(verbatim: "·").foregroundStyle(.zunoTertiary).accessibilityHidden(true)
                Button("Forgot password?") { emailMode = .reset }
                    .accessibilityIdentifier("auth.forgot")
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.zunoPrimary)
            .padding(.top, 6)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            if presentation == .root {
                Button("Explore without an account") { session.continueAsGuest() }
                    .font(.body.weight(.medium))
                    .foregroundStyle(.zunoSecondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("auth.guest")
            }
            Text("By continuing you agree to Zuno's [Terms](https://zuno.lk/terms) and [Privacy Policy](https://zuno.lk/privacy).")
                .font(.footnote)
                .tint(ZunoColor.textPrimary)
                .foregroundStyle(.zunoTertiary)
                .multilineTextAlignment(.center)
        }
    }
}

extension EmailAuthView.Mode: Identifiable {
    var id: String { rawValue }
}

/// Email and password: sign in, create account (with verification), reset password.
struct EmailAuthView: View {
    enum Mode: String { case signIn, signUp, reset }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State var initialMode: Mode
    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var model = AuthModel()
    @State private var pendingVerification: String?
    @State private var resetSent = false
    @FocusState private var focused: Field?

    enum Field { case name, email, password }

    var body: some View {
        NavigationStack {
            Form {
                if let pendingVerification {
                    verificationSection(pendingVerification)
                } else if resetSent {
                    Section {
                        Label("Check your inbox", systemImage: "envelope.badge")
                            .font(.headline)
                        Text("If an account exists for \(email), we've sent a link to reset your password. The link opens Zuno.")
                            .foregroundStyle(.zunoSecondary)
                    }
                } else {
                    formSections
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZunoColor.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Close"))
                }
            }
            .sensoryFeedback(.error, trigger: model.errorTrigger)
        }
        .presentationDetents([.large])
        .onAppear { mode = initialMode }
    }

    private var title: Text {
        switch mode {
        case .signIn: Text("Sign in")
        case .signUp: Text("Create account")
        case .reset: Text("Reset password")
        }
    }

    @ViewBuilder
    private var formSections: some View {
        Section {
            if mode == .signUp {
                TextField("Your name", text: $name)
                    .textContentType(.name)
                    .focused($focused, equals: .name)
                    .accessibilityIdentifier("email.name")
            }
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
                .accessibilityIdentifier("email.address")
            if mode != .reset {
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .focused($focused, equals: .password)
                    .accessibilityIdentifier("email.password")
            }
        } footer: {
            if mode == .signUp {
                Text("Use at least \(PasswordPolicy.minimumLength) characters with letters and numbers. We'll email you a link to confirm your address.")
            }
        }
        .listRowBackground(ZunoColor.surface)

        if let error = model.errorMessage {
            Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color(uiColor: .systemRed)) }
                .listRowBackground(ZunoColor.surface)
                .accessibilityIdentifier("email.error")
        }

        Section {
            Button {
                Task { await submit() }
            } label: {
                Text(mode == .signIn ? "Sign in" : mode == .signUp ? "Create account" : "Send reset link")
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(compact: true, isLoading: model.inProgress != nil))
            .disabled(!isValid || model.inProgress != nil)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("email.submit")
        }

        Section {
            switch mode {
            case .signIn:
                Button("New to Zuno? Create an account") { mode = .signUp }
                Button("Forgot password?") { mode = .reset }
            case .signUp, .reset:
                Button("Already have an account? Sign in") { mode = .signIn }
            }
        }
        .foregroundStyle(.zunoPrimary)
        .listRowBackground(Color.clear)
    }

    private func verificationSection(_ address: String) -> some View {
        Section {
            Label("Confirm your email", systemImage: "envelope.badge")
                .font(.headline)
            Text("We sent a confirmation link to \(address). Open it on this iPhone to finish creating your account.")
                .foregroundStyle(.zunoSecondary)
            Button("Resend email") {
                Task { await model.run(.email) { try await environment.auth.resendConfirmation(email: address) } }
            }
            Button("Back to sign in") {
                pendingVerification = nil
                mode = .signIn
            }
        }
        .listRowBackground(ZunoColor.surface)
        .zunoContainer("email.verification")
    }

    private var isValid: Bool {
        let emailOK = email.contains("@") && email.contains(".")
        switch mode {
        case .signIn: return emailOK && !password.isEmpty
        case .signUp: return emailOK && PasswordPolicy.isAcceptable(password) && name.trimmingCharacters(in: .whitespaces).count >= 2
        case .reset: return emailOK
        }
    }

    private func submit() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mode {
        case .signIn:
            await model.run(.email) { try await environment.auth.signIn(email: trimmedEmail, password: password) }
            if model.errorMessage == nil { dismiss() }
        case .signUp:
            var outcome: SignUpOutcome?
            await model.run(.email) {
                outcome = try await environment.auth.signUp(email: trimmedEmail, password: password, displayName: name)
            }
            switch outcome {
            case .confirmationRequired(let address)?: pendingVerification = address
            case .signedIn?: dismiss()
            case nil: break
            }
        case .reset:
            await model.run(.email) { try await environment.auth.sendPasswordReset(email: trimmedEmail) }
            if model.errorMessage == nil { resetSent = true }
        }
    }
}

/// Shown after a password-recovery link signs the user in.
struct PasswordRecoveryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var model = AuthModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New password", text: $password).textContentType(.newPassword)
                } footer: {
                    Text("At least \(PasswordPolicy.minimumLength) characters with letters and numbers.")
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
                Button("Save password") {
                    Task {
                        await model.run(.email) { try await environment.auth.updatePassword(password) }
                        if model.errorMessage == nil { dismiss() }
                    }
                }
                .disabled(!PasswordPolicy.isAcceptable(password))
            }
            .navigationTitle(Text("Choose a new password"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
