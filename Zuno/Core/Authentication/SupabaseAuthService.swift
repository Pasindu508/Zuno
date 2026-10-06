import Foundation
import Supabase

/// Supabase Auth implementation. Every provider ends in a Supabase session; profile,
/// wallet, ticket and organizer data are keyed by the stable Supabase user ID only.
final class SupabaseAuthService: AuthService {
    private let client: SupabaseClient
    private let redirectURL: URL
    private let web: WebAuthenticationRunning
    private static let googleScopes = "openid email profile"

    init(client: SupabaseClient, redirectURL: URL, web: WebAuthenticationRunning) {
        self.client = client
        self.redirectURL = redirectURL
        self.web = web
    }

    func authEvents() -> AsyncStream<AuthSnapshot> {
        let client = self.client
        return AsyncStream { continuation in
            let task = Task {
                for await (event, session) in client.auth.authStateChanges {
                    switch event {
                    case .initialSession:
                        guard let session else {
                            continuation.yield(AuthSnapshot(user: nil, event: .initial))
                            continue
                        }
                        if session.isExpired {
                            // A stored session past expiry: try one refresh before giving up.
                            do {
                                let refreshed = try await client.auth.refreshSession()
                                continuation.yield(AuthSnapshot(user: Self.user(from: refreshed.user), event: .initial))
                            } catch {
                                try? await client.auth.signOut(scope: .local)
                                continuation.yield(AuthSnapshot(user: nil, event: .sessionExpired))
                            }
                        } else {
                            continuation.yield(AuthSnapshot(user: Self.user(from: session.user), event: .initial))
                        }
                    case .signedIn, .mfaChallengeVerified:
                        continuation.yield(AuthSnapshot(user: session.map { Self.user(from: $0.user) }, event: .signedIn))
                    case .tokenRefreshed:
                        continuation.yield(AuthSnapshot(user: session.map { Self.user(from: $0.user) }, event: .tokenRefreshed))
                    case .userUpdated:
                        continuation.yield(AuthSnapshot(user: session.map { Self.user(from: $0.user) }, event: .userUpdated))
                    case .passwordRecovery:
                        continuation.yield(AuthSnapshot(user: session.map { Self.user(from: $0.user) }, event: .passwordRecovery))
                    case .signedOut, .userDeleted:
                        continuation.yield(AuthSnapshot(user: nil, event: .signedOut))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Sign in

    func signInWithApple(_ credential: AppleCredential) async throws {
        do {
            try await client.auth.signInWithIdToken(credentials: OpenIDConnectCredentials(
                provider: .apple, idToken: credential.identityToken, nonce: credential.rawNonce
            ))
            // Apple shares the name only on the first authorization: persist it now.
            if let name = credential.formattedName {
                _ = try? await client.auth.update(user: UserAttributes(data: ["full_name": .string(name)]))
            }
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func signInWithGoogle() async throws {
        let web = self.web
        let redirect = redirectURL
        do {
            try await client.auth.signInWithOAuth(
                provider: .google,
                redirectTo: redirect,
                scopes: Self.googleScopes
            ) { @MainActor url in
                let callback = try await web.run(url: url, callbackScheme: redirect.scheme ?? "zuno")
                return try OAuthCallback.validate(callback, expected: redirect)
            }
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func signIn(email: String, password: String) async throws {
        do {
            try await client.auth.signIn(email: email, password: password)
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        do {
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: ["full_name": .string(displayName)],
                redirectTo: redirectURL
            )
            return response.session == nil ? .confirmationRequired(email: email) : .signedIn
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func resendConfirmation(email: String) async throws {
        do {
            try await client.auth.resend(email: email, type: .signup, emailRedirectTo: redirectURL)
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func sendPasswordReset(email: String) async throws {
        do {
            try await client.auth.resetPasswordForEmail(email, redirectTo: redirectURL)
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func updatePassword(_ newPassword: String) async throws {
        do {
            _ = try await client.auth.update(user: UserAttributes(password: newPassword))
        } catch {
            throw Self.mapAuth(error)
        }
    }

    /// Email confirmation and password-recovery links arrive as `zuno://auth/callback?...`.
    func handle(url: URL) async -> Bool {
        guard url.scheme == redirectURL.scheme, url.host == redirectURL.host else { return false }
        do {
            _ = try OAuthCallback.validate(url, expected: redirectURL)
            try await client.auth.session(from: url)
            return true
        } catch {
            return false
        }
    }

    func signOut() async {
        try? await client.auth.signOut(scope: .local)
    }

    /// Account deletion runs on a trusted Edge Function (Auth Admin API never ships in the app).
    func deleteAccount() async throws {
        do {
            try await client.functions.invoke("delete-account", options: FunctionInvokeOptions(body: ["confirm": "DELETE"]))
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
        try? await client.auth.signOut(scope: .local)
    }

    // MARK: Identity linking

    func linkedIdentities() async throws -> [LinkedIdentity] {
        do {
            return try await client.auth.userIdentities().compactMap { identity in
                guard let provider = AuthProviderKind(rawValue: identity.provider) else { return nil }
                var email: String?
                if case .string(let value)? = identity.identityData?["email"] { email = value }
                return LinkedIdentity(id: identity.identityId.uuidString, provider: provider, email: email, linkedAt: identity.createdAt)
            }
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func linkApple(_ credential: AppleCredential) async throws {
        do {
            try await client.auth.linkIdentityWithIdToken(credentials: OpenIDConnectCredentials(
                provider: .apple, idToken: credential.identityToken, nonce: credential.rawNonce
            ))
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func linkGoogle() async throws {
        do {
            let response = try await client.auth.getLinkIdentityURL(provider: .google, scopes: Self.googleScopes, redirectTo: redirectURL)
            let callback = try await web.run(url: response.url, callbackScheme: redirectURL.scheme ?? "zuno")
            try await client.auth.session(from: try OAuthCallback.validate(callback, expected: redirectURL))
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func addEmailPassword(email: String, password: String) async throws {
        do {
            _ = try await client.auth.update(user: UserAttributes(email: email, password: password), redirectTo: redirectURL)
        } catch {
            throw Self.mapAuth(error)
        }
    }

    func unlink(_ identity: LinkedIdentity) async throws {
        do {
            let identities = try await client.auth.userIdentities()
            guard identities.count > 1 else { throw AuthFlowError.lastIdentity }
            guard let target = identities.first(where: { $0.identityId.uuidString == identity.id }) else { return }
            try await client.auth.unlinkIdentity(target)
            _ = try? await client.auth.refreshSession()
        } catch {
            throw Self.mapAuth(error)
        }
    }

    // MARK: Mapping

    private static func user(from user: User) -> AuthUser {
        var nameHint: String?
        if case .string(let name)? = user.userMetadata["full_name"] { nameHint = name }
        else if case .string(let name)? = user.userMetadata["name"] { nameHint = name }
        let providers = (user.identities ?? []).map(\.provider)
        return AuthUser(
            id: user.id,
            email: user.email,
            isEmailConfirmed: user.emailConfirmedAt != nil || providers.contains { $0 != "email" },
            providers: providers,
            displayNameHint: nameHint
        )
    }

    static func mapAuth(_ error: Error) -> Error {
        if let flow = error as? AuthFlowError { return flow }
        if error is CancellationError { return AuthFlowError.cancelled }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? AuthFlowError.cancelled : AuthFlowError.network
        }
        guard let auth = error as? AuthError else { return SupabaseErrorMapper.map(error) }
        switch auth.errorCode {
        case .invalidCredentials: return AuthFlowError.invalidCredentials
        case .emailNotConfirmed: return AuthFlowError.emailNotConfirmed
        case .weakPassword: return AuthFlowError.weakPassword
        case .emailExists, .userAlreadyExists: return AuthFlowError.emailInUse
        case .identityAlreadyExists: return AuthFlowError.identityAlreadyLinked
        case .singleIdentityNotDeletable: return AuthFlowError.lastIdentity
        case .manualLinkingDisabled: return AuthFlowError.manualLinkingDisabled
        case .flowStateExpired, .flowStateNotFound, .badOAuthState, .badCodeVerifier: return AuthFlowError.flowExpired
        case .badOAuthCallback: return AuthFlowError.callbackMismatch
        case .sessionNotFound, .sessionExpired, .refreshTokenNotFound: return AuthFlowError.missingSession
        case .overRequestRateLimit, .overEmailSendRateLimit: return ZunoError.rateLimited
        default:
            if case .pkceGrantCodeExchange(_, let code?, _) = auth, code == "access_denied" { return AuthFlowError.consentDenied }
            return AuthFlowError.provider(auth.message)
        }
    }
}

extension ErrorCode {
    /// Supabase returns `invalid_credentials` for a wrong email/password pair.
    static let invalidCredentials = ErrorCode("invalid_credentials")
}
