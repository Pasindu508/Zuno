import AuthenticationServices
import Supabase
import XCTest
@testable import Zuno

// MARK: - Test doubles (test target only — never compiled into the app)

/// Intercepts every request made by a Supabase client built for tests.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let url: URL
        let method: String
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest, Data) -> (Int, Data))?
    nonisolated(unsafe) private static var _requests: [Recorded] = []

    static func setHandler(_ handler: @escaping @Sendable (URLRequest, Data) -> (Int, Data)) {
        lock.withLock { _handler = handler; _requests = [] }
    }

    static var requests: [Recorded] { lock.withLock { _requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
        }
        let handler = Self.lock.withLock { () -> (@Sendable (URLRequest, Data) -> (Int, Data))? in
            Self._requests.append(Recorded(url: request.url!, method: request.httpMethod ?? "GET", body: body))
            return Self._handler
        }
        let (status, data) = handler?(request, body) ?? (404, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// In-memory session storage so tests never touch the real Keychain session.
final class InMemoryAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private var values: [String: Data] = [:]
    private let lock = NSLock()
    func store(key: String, value: Data) throws { lock.withLock { values[key] = value } }
    func retrieve(key: String) throws -> Data? { lock.withLock { values[key] } }
    func remove(key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
}

/// Records the authorize URL and returns a scripted callback.
final class ScriptedWebRunner: WebAuthenticationRunning, @unchecked Sendable {
    var callback: Result<URL, Error>
    private(set) var openedURL: URL?
    init(callback: Result<URL, Error>) { self.callback = callback }
    @MainActor func run(url: URL, callbackScheme: String) async throws -> URL {
        openedURL = url
        return try callback.get()
    }
}

enum SupabaseFixtures {
    static let userID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static func base64URL(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func jwt(expiresIn: TimeInterval = 3600) -> String {
        let exp = Int(Date.now.timeIntervalSince1970 + expiresIn)
        return [base64URL(#"{"alg":"HS256","typ":"JWT"}"#),
                base64URL(#"{"sub":"\#(userID.uuidString.lowercased())","role":"authenticated","aud":"authenticated","exp":\#(exp)}"#),
                "signature"].joined(separator: ".")
    }

    static func userJSON(provider: String) -> String {
        """
        {"id":"\(userID.uuidString.lowercased())","aud":"authenticated","role":"authenticated","email":"nethmi@example.com",
         "email_confirmed_at":"2026-10-06T10:00:00Z","app_metadata":{"provider":"\(provider)","providers":["\(provider)"]},
         "user_metadata":{"full_name":"Nethmi Perera"},
         "identities":[{"id":"provider-sub","identity_id":"99999999-2222-4333-8444-555555555555","user_id":"\(userID.uuidString.lowercased())",
           "identity_data":{"email":"nethmi@example.com"},"provider":"\(provider)","created_at":"2026-10-06T10:00:00Z",
           "last_sign_in_at":"2026-10-06T10:00:00Z","updated_at":"2026-10-06T10:00:00Z"}],
         "created_at":"2026-10-06T10:00:00Z","updated_at":"2026-10-06T10:00:00Z"}
        """
    }

    static func sessionJSON(provider: String) -> Data {
        let expiresAt = Int(Date.now.timeIntervalSince1970 + 3600)
        return Data("""
        {"access_token":"\(jwt())","token_type":"bearer","expires_in":3600,"expires_at":\(expiresAt),
         "refresh_token":"refresh-token","user":\(userJSON(provider: provider))}
        """.utf8)
    }

    static func client(storage: AuthLocalStorage = InMemoryAuthStorage()) -> SupabaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return SupabaseClient(
            supabaseURL: URL(string: "https://zuno-test.supabase.co")!,
            supabaseKey: "sb_publishable_test",
            options: SupabaseClientOptions(
                auth: .init(storage: storage, redirectToURL: URL(string: "zuno://auth/callback")!, storageKey: "zuno-tests",
                            flowType: .pkce, autoRefreshToken: false, emitLocalSessionAsInitialSession: true),
                global: .init(session: URLSession(configuration: configuration))
            )
        )
    }
}

// MARK: - Apple

final class AppleSignInTests: XCTestCase {
    func testNonceIsRandomAndUsesSafeAlphabet() throws {
        let a = try AppleNonce.generate(), b = try AppleNonce.generate()
        XCTAssertEqual(a.count, 32)
        XCTAssertNotEqual(a, b)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        XCTAssertTrue(a.allSatisfy(allowed.contains))
    }

    func testSHA256OfNonceMatchesKnownVector() {
        XCTAssertEqual(AppleNonce.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    /// The raw nonce (not the hash) goes to Supabase with the identity token; the name Apple
    /// shares on first authorization is saved to user metadata.
    func testIdentityTokenExchangeSendsRawNonceAndSavesName() async throws {
        MockURLProtocol.setHandler { request, _ in
            if request.url!.path.hasSuffix("/token") { return (200, SupabaseFixtures.sessionJSON(provider: "apple")) }
            if request.url!.path.hasSuffix("/user") { return (200, Data(SupabaseFixtures.userJSON(provider: "apple").utf8)) }
            return (404, Data())
        }
        let service = SupabaseAuthService(client: SupabaseFixtures.client(), redirectURL: URL(string: "zuno://auth/callback")!,
                                          web: ScriptedWebRunner(callback: .failure(AuthFlowError.cancelled)))
        var name = PersonNameComponents()
        name.givenName = "Nethmi"
        name.familyName = "Perera"
        let credential = AppleCredential(identityToken: "apple.identity.token", rawNonce: "raw-nonce-123",
                                         userIdentifier: "001234.abc", fullName: name, email: "x@privaterelay.appleid.com")
        try await service.signInWithApple(credential)

        let tokenRequest = try XCTUnwrap(MockURLProtocol.requests.first { $0.url.path.hasSuffix("/token") })
        XCTAssertEqual(URLComponents(url: tokenRequest.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant_type" }?.value, "id_token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: tokenRequest.body) as? [String: Any])
        XCTAssertEqual(body["provider"] as? String, "apple")
        XCTAssertEqual(body["id_token"] as? String, "apple.identity.token")
        XCTAssertEqual(body["nonce"] as? String, "raw-nonce-123")
        let userUpdate = try XCTUnwrap(MockURLProtocol.requests.first { $0.url.path.hasSuffix("/user") && $0.method == "PUT" })
        XCTAssertTrue(String(decoding: userUpdate.body, as: UTF8.self).contains("Nethmi Perera"))
    }

    func testRejectedTokenMapsToProviderError() async {
        MockURLProtocol.setHandler { _, _ in
            (400, Data(#"{"code":400,"error_code":"bad_jwt","msg":"Bad ID token"}"#.utf8))
        }
        let service = SupabaseAuthService(client: SupabaseFixtures.client(), redirectURL: URL(string: "zuno://auth/callback")!,
                                          web: ScriptedWebRunner(callback: .failure(AuthFlowError.cancelled)))
        do {
            try await service.signInWithApple(AppleCredential(identityToken: "bad", rawNonce: "n", userIdentifier: "u", fullName: nil, email: nil))
            XCTFail("expected failure")
        } catch {
            XCTAssertNotNil(error as? AuthFlowError)
        }
    }
}

// MARK: - Google

final class GoogleOAuthTests: XCTestCase {
    let redirect = URL(string: "zuno://auth/callback")!

    func testCallbackValidation() throws {
        XCTAssertNoThrow(try OAuthCallback.validate(URL(string: "zuno://auth/callback?code=abc")!, expected: redirect))
        XCTAssertThrowsError(try OAuthCallback.validate(URL(string: "evil://auth/callback?code=abc")!, expected: redirect)) {
            XCTAssertEqual($0 as? AuthFlowError, .callbackMismatch)
        }
        XCTAssertThrowsError(try OAuthCallback.validate(URL(string: "zuno://payments/return?code=abc")!, expected: redirect)) {
            XCTAssertEqual($0 as? AuthFlowError, .callbackMismatch)
        }
        XCTAssertThrowsError(try OAuthCallback.validate(URL(string: "zuno://auth/callback?error=access_denied&error_description=User+denied")!, expected: redirect)) {
            XCTAssertEqual($0 as? AuthFlowError, .consentDenied)
        }
        XCTAssertThrowsError(try OAuthCallback.validate(URL(string: "zuno://auth/callback?error=invalid_request&error_code=flow_state_expired&error_description=Flow+expired")!, expected: redirect)) {
            XCTAssertEqual($0 as? AuthFlowError, .flowExpired)
        }
        XCTAssertThrowsError(try OAuthCallback.validate(URL(string: "zuno://auth/callback")!, expected: redirect)) {
            XCTAssertEqual($0 as? AuthFlowError, .missingSession)
        }
        XCTAssertNoThrow(try OAuthCallback.validate(URL(string: "zuno://auth/callback#access_token=a&refresh_token=b")!, expected: redirect))
    }

    func testPKCEFlowRequestsMinimalScopesAndExchangesCode() async throws {
        MockURLProtocol.setHandler { request, _ in
            request.url!.path.hasSuffix("/token") ? (200, SupabaseFixtures.sessionJSON(provider: "google")) : (404, Data())
        }
        let runner = ScriptedWebRunner(callback: .success(URL(string: "zuno://auth/callback?code=auth-code-1")!))
        let service = SupabaseAuthService(client: SupabaseFixtures.client(), redirectURL: redirect, web: runner)
        try await service.signInWithGoogle()

        let opened = try XCTUnwrap(runner.openedURL)
        let items = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("provider"), "google")
        XCTAssertEqual(value("scopes"), "openid email profile")
        XCTAssertEqual(value("redirect_to"), "zuno://auth/callback")
        XCTAssertEqual(value("code_challenge_method")?.lowercased(), "s256")
        XCTAssertNotNil(value("code_challenge"))

        let exchange = try XCTUnwrap(MockURLProtocol.requests.first { $0.url.path.hasSuffix("/token") })
        XCTAssertEqual(URLComponents(url: exchange.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "grant_type" }?.value, "pkce")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: exchange.body) as? [String: Any])
        XCTAssertEqual(body["auth_code"] as? String, "auth-code-1")
        XCTAssertNotNil(body["code_verifier"] as? String)
    }

    func testCancellationAndMismatchAreTyped() async {
        MockURLProtocol.setHandler { _, _ in (500, Data()) }
        let cancelled = SupabaseAuthService(client: SupabaseFixtures.client(), redirectURL: redirect,
                                            web: ScriptedWebRunner(callback: .failure(AuthFlowError.cancelled)))
        do { try await cancelled.signInWithGoogle(); XCTFail() } catch {
            XCTAssertEqual(error as? AuthFlowError, .cancelled)
        }
        let mismatched = SupabaseAuthService(client: SupabaseFixtures.client(), redirectURL: redirect,
                                             web: ScriptedWebRunner(callback: .success(URL(string: "zuno://elsewhere?code=x")!)))
        do { try await mismatched.signInWithGoogle(); XCTFail() } catch {
            XCTAssertEqual(error as? AuthFlowError, .callbackMismatch)
        }
        XCTAssertFalse(MockURLProtocol.requests.contains { $0.url.path.hasSuffix("/token") }, "no exchange is attempted")
    }

    @MainActor
    func testAuthModelSwallowsCancellation() async {
        let model = AuthModel()
        await model.run(.google) { throw AuthFlowError.cancelled }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.errorTrigger, 0)
        await model.run(.google) { throw AuthFlowError.consentDenied }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.errorTrigger, 1)
    }
}

// MARK: - Session routing, restoration and expiry

/// Scriptable auth service for routing tests.
final class ScriptedAuthService: AuthService, @unchecked Sendable {
    let stream: AsyncStream<AuthSnapshot>
    let continuation: AsyncStream<AuthSnapshot>.Continuation
    init() { (stream, continuation) = AsyncStream<AuthSnapshot>.makeStream() }
    func authEvents() -> AsyncStream<AuthSnapshot> { stream }
    func signInWithApple(_ credential: AppleCredential) async throws {}
    func signInWithGoogle() async throws {}
    func signIn(email: String, password: String) async throws {}
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome { .signedIn }
    func resendConfirmation(email: String) async throws {}
    func sendPasswordReset(email: String) async throws {}
    func updatePassword(_ newPassword: String) async throws {}
    func handle(url: URL) async -> Bool { false }
    func signOut() async { continuation.yield(AuthSnapshot(user: nil, event: .signedOut)) }
    func deleteAccount() async throws {}
    func linkedIdentities() async throws -> [LinkedIdentity] { [] }
    func linkApple(_ credential: AppleCredential) async throws {}
    func linkGoogle() async throws {}
    func addEmailPassword(email: String, password: String) async throws {}
    func unlink(_ identity: LinkedIdentity) async throws {}
}

@MainActor
final class SessionRoutingTests: XCTestCase {
    private func environment(auth: AuthService, backend: DevelopmentBackend, onboarded: Bool = true) -> AppEnvironment {
        let defaults = UserDefaults(suiteName: "zuno-tests-\(UUID().uuidString)")!
        let preferences = AppPreferences(defaults: defaults)
        preferences.hasCompletedOnboarding = onboarded
        return AppEnvironment(
            configuration: AppConfiguration(environment: .test, supabaseURL: nil, supabasePublishableKey: nil),
            backend: .development, auth: auth, events: backend, registrations: backend, checkout: backend, wallet: backend,
            tickets: backend, profiles: backend, notifications: backend, organizer: backend, checkIn: backend,
            appleAuthorizer: StubAppleAuthorizer(),
            biometrics: BiometricGate(authenticator: StubLocalAuthenticator(outcome: .success), keychain: Keychain(service: "zuno-tests")),
            scanner: StubScannerProvider(code: "x"), preferences: preferences, network: NetworkMonitor(start: false)
        )
    }

    private func waitForRoute(_ store: SessionStore, _ route: SessionStore.Route, timeout: TimeInterval = 5) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        while store.route != route && Date.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.route, route)
    }

    func testRestoredSessionWithCompleteProfileRoutesHome() async {
        let backend = await DevelopmentBackend()
        await backend.setLatency(.zero)
        let auth = await DevelopmentAuthService(backend: backend, apple: StubAppleAuthorizer(), startSignedIn: true)
        let store = SessionStore(environment: environment(auth: auth, backend: backend))
        store.start()
        await waitForRoute(store, .main)
        XCTAssertEqual(store.profile?.displayName, "Nethmi Perera")
        await auth.signOut()
    }

    func testNewUserIsRoutedThroughProfileAndIdentitySetup() async throws {
        let backend = await DevelopmentBackend()
        await backend.setLatency(.zero)
        let auth = ScriptedAuthService()
        let env = environment(auth: auth, backend: backend)
        let store = SessionStore(environment: env)
        store.start()
        auth.continuation.yield(AuthSnapshot(user: nil, event: .initial))
        await waitForRoute(store, .auth)

        let newUser = AuthUser(id: UUID(), email: "new@example.com", isEmailConfirmed: true, providers: ["google"], displayNameHint: "Amaya")
        await backend.signIn(userID: newUser.id, email: newUser.email, displayName: nil, completeProfile: false)
        auth.continuation.yield(AuthSnapshot(user: newUser, event: .signedIn))
        await waitForRoute(store, .profileSetup)

        var draft = ProfileDraft()
        draft.displayName = "Amaya Silva"
        store.profileUpdated(try await backend.saveProfile(draft, markOnboardingComplete: true))
        XCTAssertEqual(store.route, .identitySetup)
        _ = try await backend.submitNationalIdentifier("200198765432")
        await store.identityCompleted()
        XCTAssertEqual(store.route, .main)
    }

    func testExpiredSessionSignsOutWithNotice() async {
        let backend = await DevelopmentBackend()
        let auth = ScriptedAuthService()
        let store = SessionStore(environment: environment(auth: auth, backend: backend))
        store.start()
        auth.continuation.yield(AuthSnapshot(user: nil, event: .sessionExpired))
        await waitForRoute(store, .auth)
        XCTAssertNotNil(store.notice)
    }

    func testGuestIntentIsPreservedUntilSignIn() async {
        let backend = await DevelopmentBackend()
        let auth = ScriptedAuthService()
        let store = SessionStore(environment: environment(auth: auth, backend: backend))
        store.start()
        auth.continuation.yield(AuthSnapshot(user: nil, event: .initial))
        await waitForRoute(store, .auth)
        store.continueAsGuest()
        XCTAssertEqual(store.route, .main)
        let eventID = UUID()
        store.requireAccount(for: .register(eventID: eventID))
        XCTAssertTrue(store.isAuthSheetPresented)
        XCTAssertEqual(store.consumePendingIntent(), .register(eventID: eventID))
        XCTAssertNil(store.consumePendingIntent())
    }

    func testFirstLaunchShowsOnboarding() async {
        let backend = await DevelopmentBackend()
        let auth = ScriptedAuthService()
        let store = SessionStore(environment: environment(auth: auth, backend: backend, onboarded: false))
        store.start()
        auth.continuation.yield(AuthSnapshot(user: nil, event: .initial))
        await waitForRoute(store, .onboarding)
        store.completeOnboarding(browseAsGuest: false)
        XCTAssertEqual(store.route, .auth)
    }
}

// MARK: - Identity linking and biometrics

final class IdentityLinkingTests: XCTestCase {
    func testLinkAndUnlinkKeepAtLeastOneMethod() async throws {
        let backend = await DevelopmentBackend()
        let auth = await DevelopmentAuthService(backend: backend, apple: StubAppleAuthorizer(), startSignedIn: false)
        try await auth.signIn(email: "someone@example.com", password: "correct-horse-1")
        var identities = try await auth.linkedIdentities()
        XCTAssertEqual(identities.map(\.provider), [.email])
        do {
            try await auth.unlink(identities[0])
            XCTFail("cannot remove the last method")
        } catch {
            XCTAssertEqual(error as? AuthFlowError, .lastIdentity)
        }
        try await auth.linkGoogle()
        identities = try await auth.linkedIdentities()
        XCTAssertEqual(Set(identities.map(\.provider)), [.email, .google])
        do {
            try await auth.linkGoogle()
            XCTFail("double-linking the same provider must fail")
        } catch {
            XCTAssertEqual(error as? AuthFlowError, .identityAlreadyLinked)
        }
        try await auth.unlink(identities.first { $0.provider == .email }!)
        identities = try await auth.linkedIdentities()
        XCTAssertEqual(identities.map(\.provider), [.google])
        await auth.signOut()
    }

    func testWrongPasswordIsRejected() async {
        let backend = await DevelopmentBackend()
        let auth = await DevelopmentAuthService(backend: backend, apple: StubAppleAuthorizer(), startSignedIn: false)
        do {
            try await auth.signIn(email: "someone@example.com", password: "wrong-password")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? AuthFlowError, .invalidCredentials)
        }
    }

    @MainActor
    func testIdentityLinkingAlwaysRequiresFreshLocalAuthentication() async {
        let keychain = Keychain(service: "zuno-tests-\(UUID().uuidString)")
        let failing = BiometricGate(authenticator: StubLocalAuthenticator(outcome: .failed), keychain: keychain)
        XCTAssertFalse(failing.isAppLockEnabled)
        XCTAssertFalse(failing.requiresUnlock(.walletDetails), "optional protection is off by default")
        XCTAssertTrue(failing.requiresUnlock(.identityLinking), "linking always needs fresh authentication")
        let allowed = await failing.authorize(.identityLinking)
        XCTAssertFalse(allowed)
        let passing = BiometricGate(authenticator: StubLocalAuthenticator(outcome: .success), keychain: keychain)
        let ok = await passing.authorize(.identityLinking)
        XCTAssertTrue(ok)
        XCTAssertTrue(passing.requiresUnlock(.identityLinking), "no grace period for identity changes")
    }

    @MainActor
    func testAppLockProtectsWalletWithGracePeriod() async {
        let keychain = Keychain(service: "zuno-tests-\(UUID().uuidString)")
        let gate = BiometricGate(authenticator: StubLocalAuthenticator(outcome: .success), keychain: keychain)
        let enabled = await gate.setAppLock(enabled: true)
        XCTAssertTrue(enabled)
        XCTAssertTrue(gate.requiresUnlock(.walletDetails))
        let unlocked = await gate.authorize(.walletDetails)
        XCTAssertTrue(unlocked)
        XCTAssertFalse(gate.requiresUnlock(.walletDetails), "within the grace period")
        gate.lock()
        XCTAssertTrue(gate.requiresUnlock(.walletDetails), "backgrounding clears unlocks")
        gate.reset()
        keychain.removeAll()
    }
}

// MARK: - Contract decoding

final class ContractDecodingTests: XCTestCase {
    func testEventDetailEnvelopeDecodes() throws {
        let json = """
        {"event":{"id":"e1000000-0000-4000-8000-000000000003","title":"Kandyan Drumming Circle","summary":"An evening of rhythms",
          "category_id":"culture","category_name":"Culture","organizer_id":"6f1d0a3e-1c2b-4d5e-8f90-0a1b2c3d4e02","organizer_name":"Kandy Arts Guild",
          "venue_name":"Lakeside Pavilion","city":"Kandy","district":"Kandy","latitude":7.29,"longitude":80.64,"university":null,"format":"physical",
          "starts_at":"2026-10-15T12:00:00+00:00","ends_at":"2026-10-15T14:30:00.000000+00:00","is_free":false,"min_price_minor":150000,
          "currency":"LKR","capacity":180,"seats_taken":89,"seats_remaining":91,"cover_path":"seed/kandyan-drumming.jpg","cover_alt":"Drums",
          "tags":["drumming"],"status":"published","published_at":null,"description":"Master drummers…",
          "agenda":[{"starts_at":"2026-10-15T12:00:00+00:00","ends_at":"2026-10-15T12:30:00+00:00","title":"Welcome","detail":""}],
          "speakers":[{"name":"Gunadasa Herath","role":"Master drummer","organization":"Kandy Arts Guild"}],
          "refund_policy":"Full refund as wallet credit","registration_opens_at":null,"registration_closes_at":"2026-10-15T12:00:00+00:00",
          "online_url":null,"address_line":"Sangaraja Mawatha","organizer_slug":"kandy-arts-guild","organizer_verified":true},
         "tiers":[{"id":"f1000000-0000-4000-8000-000000000031","name":"Standard","description":"Lakeside seating","price_minor":150000,"currency":"LKR",
           "quantity":150,"remaining":88,"max_per_order":6,"sales_start_at":null,"sales_end_at":"2026-10-15T12:00:00+00:00","on_sale":true}],
         "questions":[], "media":[], "viewer":{"is_saved":true,"registration_status":null,"registration_id":null,"waitlisted":false,"is_organizer":false}}
        """
        let detail = try JSONDecoder.zunoSnake.decode(EventDetailEnvelope.self, from: Data(json.utf8)).domain
        XCTAssertEqual(detail.summary.title, "Kandyan Drumming Circle")
        XCTAssertEqual(detail.summary.minPrice, .lkr(150_000))
        XCTAssertEqual(detail.summary.seatsRemaining, 91)
        XCTAssertEqual(detail.summary.cover, .storage(bucket: "event-media", path: "seed/kandyan-drumming.jpg"))
        XCTAssertEqual(detail.tiers.first?.remaining, 88)
        XCTAssertEqual(detail.agenda.first?.title, "Welcome")
        XCTAssertTrue(detail.viewer.isSaved)
        XCTAssertTrue(detail.organizerVerified)
    }

    func testTicketAndQuoteDecode() throws {
        let tickets = """
        [{"ticket_id":"a0000000-0000-4000-8000-000000000001","code":"ZN-4K7P-Q2MX","qr_payload":"zuno:t:abc","status":"checked_in",
          "tier_name":"General","attendee_name":"Nethmi","issued_at":"2026-10-01T10:00:00Z","checked_in_at":"2026-10-05T10:00:00Z",
          "registration_reference":"ZR-7K2M9QXA","order_id":null,
          "event":{"id":"e1000000-0000-4000-8000-000000000001","title":"Climate AI Hackathon","starts_at":"2026-10-11T03:00:00Z",
                   "ends_at":"2026-10-12T15:00:00Z","venue_name":"Innovation Hall","city":"Colombo","cover_path":null,"cover_alt":null,
                   "status":"published","category_id":"hackathons"}}]
        """
        let decoded = try JSONDecoder.zunoSnake.decode([TicketRow].self, from: Data(tickets.utf8)).map(\.domain)
        XCTAssertEqual(decoded.first?.status, .checkedIn)
        XCTAssertEqual(decoded.first?.code, "ZN-4K7P-Q2MX")

        let quote = """
        {"allowance_limit":15,"allowance_used":15,"allowance_remaining":0,"fee_minor":250,"wallet_balance_minor":14000,"currency":"LKR",
         "can_register":false,"reason":"insufficient_balance","seats_remaining":12,"month":"2026-10"}
        """
        let decodedQuote = try JSONDecoder.zunoSnake.decode(QuoteRow.self, from: Data(quote.utf8)).domain
        XCTAssertEqual(decodedQuote.reason, .insufficientBalance)
        XCTAssertEqual(decodedQuote.fee, .lkr(250))
    }

    func testServerErrorCodesMapToTypedErrors() {
        XCTAssertEqual(ZunoError.fromServerCode("sold_out"), .registration(.soldOut))
        XCTAssertEqual(ZunoError.fromServerCode("fee_changed"), .feeChanged)
        XCTAssertEqual(ZunoError.fromServerCode("rate_limited"), .rateLimited)
        XCTAssertEqual(ZunoError.fromServerCode("event_not_found"), .notFound)
        XCTAssertEqual(ZunoError.fromServerCode("ai_timeout"), .server(code: "ai_timeout", message: nil))
    }

    func testPayHereFormIsEscaped() {
        let html = PayHereCheckoutView.formHTML(actionURL: URL(string: "https://sandbox.payhere.lk/pay/checkout")!,
                                                fields: ["items": "Drums \"front\" <row>", "amount": "1500.00"])
        XCTAssertTrue(html.contains("Drums &quot;front&quot; &lt;row&gt;"))
        XCTAssertTrue(html.contains("value=\"1500.00\""))
        XCTAssertFalse(html.contains("<row>"))
    }
}
