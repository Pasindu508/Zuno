import Foundation

struct AuthUser: Hashable, Sendable {
    let id: UUID
    var email: String?
    var isEmailConfirmed: Bool
    var providers: [String]
    var displayNameHint: String?
}

enum AuthEvent: Sendable, Equatable {
    case initial, signedIn, signedOut, tokenRefreshed, userUpdated, passwordRecovery, sessionExpired
}

struct AuthSnapshot: Sendable, Equatable {
    var user: AuthUser?
    var event: AuthEvent
}

enum AuthProviderKind: String, Sendable, Hashable, CaseIterable {
    case apple, google, email

    var title: String {
        switch self {
        case .apple: "Apple"
        case .google: "Google"
        case .email: String(localized: "Email and password")
        }
    }

    var symbolName: String {
        switch self {
        case .apple: "apple.logo"
        case .google: "globe"
        case .email: "envelope"
        }
    }
}

struct LinkedIdentity: Identifiable, Hashable, Sendable {
    let id: String
    var provider: AuthProviderKind
    var email: String?
    var linkedAt: Date?
}

struct AppleCredential: Sendable, Equatable {
    var identityToken: String
    var rawNonce: String
    var userIdentifier: String
    var fullName: PersonNameComponents?
    var email: String?

    var formattedName: String? {
        guard let fullName else { return nil }
        let formatted = PersonNameComponentsFormatter.localizedString(from: fullName, style: .default)
        return formatted.trimmingCharacters(in: .whitespaces).isEmpty ? nil : formatted
    }
}

enum SignUpOutcome: Sendable, Equatable {
    case signedIn
    case confirmationRequired(email: String)
}

/// Typed authentication failures with user-facing copy.
enum AuthFlowError: LocalizedError, Equatable, Sendable {
    case cancelled
    case missingIdentityToken
    case credentialRevoked
    case callbackMismatch
    case consentDenied
    case flowExpired
    case missingSession
    case network
    case invalidCredentials
    case emailNotConfirmed
    case weakPassword
    case emailInUse
    case identityAlreadyLinked
    case lastIdentity
    case manualLinkingDisabled
    case notConfigured
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: String(localized: "Sign-in was cancelled.")
        case .missingIdentityToken: String(localized: "Apple didn't return an identity token. Please try again.")
        case .credentialRevoked: String(localized: "Your Apple ID no longer allows Zuno to sign in. Sign in again to continue.")
        case .callbackMismatch: String(localized: "The sign-in response didn't come back to Zuno correctly. Please try again.")
        case .consentDenied: String(localized: "Permission was declined, so you weren't signed in.")
        case .flowExpired: String(localized: "That sign-in attempt expired. Please start again.")
        case .missingSession: String(localized: "We couldn't complete sign-in. Please try again.")
        case .network: String(localized: "You're offline. Check your connection and try again.")
        case .invalidCredentials: String(localized: "That email and password don't match.")
        case .emailNotConfirmed: String(localized: "Confirm your email address first — check your inbox for the link.")
        case .weakPassword: String(localized: "Choose a stronger password with at least 10 characters.")
        case .emailInUse: String(localized: "An account already uses this email. Sign in instead.")
        case .identityAlreadyLinked: String(localized: "That sign-in method already belongs to another Zuno account.")
        case .lastIdentity: String(localized: "Add another sign-in method before removing this one.")
        case .manualLinkingDisabled: String(localized: "Linking sign-in methods isn't enabled on the server yet.")
        case .notConfigured: String(localized: "Sign-in isn't configured for this build.")
        case .provider(let message): message
        }
    }

    var isCancellation: Bool { self == .cancelled }
}

/// Central authentication seam. Live: Supabase Auth. DEBUG: deterministic development stub.
protocol AuthService: Sendable {
    /// Emits the initial session state first, then every subsequent change.
    func authEvents() -> AsyncStream<AuthSnapshot>
    func signInWithApple(_ credential: AppleCredential) async throws
    func signInWithGoogle() async throws
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome
    func resendConfirmation(email: String) async throws
    func sendPasswordReset(email: String) async throws
    func updatePassword(_ newPassword: String) async throws
    func handle(url: URL) async -> Bool
    func signOut() async
    func deleteAccount() async throws
    func linkedIdentities() async throws -> [LinkedIdentity]
    func linkApple(_ credential: AppleCredential) async throws
    func linkGoogle() async throws
    func addEmailPassword(email: String, password: String) async throws
    func unlink(_ identity: LinkedIdentity) async throws
}

enum PasswordPolicy {
    static let minimumLength = 10
    static func isAcceptable(_ password: String) -> Bool {
        password.count >= minimumLength && password.contains(where: \.isLetter) && password.contains(where: \.isNumber)
    }
}

/// Validates OAuth callbacks before handing them to Supabase, so mismatched or failed
/// redirects produce precise errors instead of a generic exchange failure.
enum OAuthCallback {
    static func validate(_ url: URL, expected: URL) throws -> URL {
        guard url.scheme?.lowercased() == expected.scheme?.lowercased(),
              url.host?.lowercased() == expected.host?.lowercased(),
              url.path == expected.path
        else { throw AuthFlowError.callbackMismatch }

        var items: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems?.forEach { items[$0.name] = $0.value ?? "" }
        if let fragment = components?.fragment, let fragmentItems = URLComponents(string: "?" + fragment)?.queryItems {
            fragmentItems.forEach { items[$0.name] = $0.value ?? "" }
        }

        if let error = items["error"] {
            let code = items["error_code"] ?? ""
            let description = items["error_description"] ?? ""
            if error == "access_denied" && (code.isEmpty || code == "access_denied") && !description.lowercased().contains("expired") {
                throw AuthFlowError.consentDenied
            }
            if code.contains("flow_state") || description.lowercased().contains("expired") {
                throw AuthFlowError.flowExpired
            }
            throw AuthFlowError.provider(description.isEmpty ? error : description)
        }
        guard items["code"] != nil || items["access_token"] != nil else { throw AuthFlowError.missingSession }
        return url
    }
}
