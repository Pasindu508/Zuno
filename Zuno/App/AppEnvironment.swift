import Foundation
import Observation
import Supabase

/// Dependency container. Features receive protocols, never concrete Supabase types.
@MainActor
@Observable
final class AppEnvironment {
    enum Backend: Equatable { case supabase, development, unconfigured }

    let configuration: AppConfiguration
    let backend: Backend
    let auth: AuthService
    let events: EventRepository
    let registrations: RegistrationRepository
    let checkout: CheckoutRepository
    let wallet: WalletRepository
    let tickets: TicketRepository
    let profiles: ProfileRepository
    let notifications: NotificationRepository
    let organizer: OrganizerRepository
    let checkIn: CheckInRepository
    let appleAuthorizer: AppleAuthorizing
    let ticketCache: TicketCache
    let preferences: AppPreferences
    let biometrics: BiometricGate
    let network: NetworkMonitor
    let scanner: ScannerProviding
    private let clock: @Sendable () -> Date

    var now: Date { clock() }
    var isDevelopmentBackend: Bool { backend == .development }

    init(
        configuration: AppConfiguration,
        backend: Backend,
        auth: AuthService,
        events: EventRepository,
        registrations: RegistrationRepository,
        checkout: CheckoutRepository,
        wallet: WalletRepository,
        tickets: TicketRepository,
        profiles: ProfileRepository,
        notifications: NotificationRepository,
        organizer: OrganizerRepository,
        checkIn: CheckInRepository,
        appleAuthorizer: AppleAuthorizing,
        biometrics: BiometricGate,
        scanner: ScannerProviding,
        preferences: AppPreferences = AppPreferences(),
        network: NetworkMonitor = NetworkMonitor(),
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.configuration = configuration
        self.backend = backend
        self.auth = auth
        self.events = events
        self.registrations = registrations
        self.checkout = checkout
        self.wallet = wallet
        self.tickets = tickets
        self.profiles = profiles
        self.notifications = notifications
        self.organizer = organizer
        self.checkIn = checkIn
        self.appleAuthorizer = appleAuthorizer
        self.biometrics = biometrics
        self.scanner = scanner
        self.preferences = preferences
        self.network = network
        self.clock = clock
        ticketCache = TicketCache()
    }

    /// Builds the live environment, or (Debug only) the development backend when Supabase
    /// isn't configured or a UI test asks for it.
    static func bootstrap(configuration: AppConfiguration = .current) async -> AppEnvironment {
        #if DEBUG
        if LaunchOptions.resetState {
            AppPreferences().resetAll()
            Keychain.standard.removeAll()
            Keychain(service: "lk.zuno.app.dev-session").removeAll()
            await TicketCache().clear()
        }
        if LaunchOptions.useDevelopmentBackend || !configuration.isSupabaseConfigured {
            return await makeDevelopment(configuration: configuration)
        }
        #endif
        guard let client = SupabaseClientProvider.make(configuration: configuration) else {
            return makeUnconfigured(configuration: configuration)
        }
        let gateway = SupabaseGateway(client: client)
        await ImagePipeline.shared.configure(source: SupabaseImageDataSource(
            client: client, publicSource: URLImageDataSource(storageBaseURL: configuration.supabaseURL)
        ))
        let organizer = SupabaseOrganizerRepository(gateway: gateway, aiFunctionName: configuration.aiFunctionName)
        return AppEnvironment(
            configuration: configuration,
            backend: .supabase,
            auth: SupabaseAuthService(client: client, redirectURL: configuration.oauthRedirectURL, web: SystemWebAuthenticationRunner()),
            events: SupabaseEventRepository(gateway: gateway),
            registrations: SupabaseRegistrationRepository(gateway: gateway),
            checkout: SupabaseCheckoutRepository(gateway: gateway),
            wallet: SupabaseWalletRepository(gateway: gateway),
            tickets: SupabaseTicketRepository(gateway: gateway),
            profiles: SupabaseProfileRepository(gateway: gateway),
            notifications: SupabaseNotificationRepository(gateway: gateway),
            organizer: organizer,
            checkIn: SupabaseCheckInRepository(gateway: gateway),
            appleAuthorizer: SystemAppleAuthorizer(),
            biometrics: BiometricGate(authenticator: SystemLocalAuthenticator()),
            scanner: CameraScannerProvider()
        )
    }

    private static func makeUnconfigured(configuration: AppConfiguration) -> AppEnvironment {
        let unconfigured = UnconfiguredBackend()
        return AppEnvironment(
            configuration: configuration, backend: .unconfigured, auth: unconfigured, events: unconfigured,
            registrations: unconfigured, checkout: unconfigured, wallet: unconfigured, tickets: unconfigured,
            profiles: unconfigured, notifications: unconfigured, organizer: unconfigured, checkIn: unconfigured,
            appleAuthorizer: SystemAppleAuthorizer(), biometrics: BiometricGate(authenticator: SystemLocalAuthenticator()),
            scanner: CameraScannerProvider()
        )
    }

    #if DEBUG
    static func makeDevelopment(configuration: AppConfiguration = .current) async -> AppEnvironment {
        let fixedNow = LaunchOptions.fixedNow
        let clock: @Sendable () -> Date
        if let fixedNow { clock = { fixedNow } } else { clock = { .now } }
        let backend = await DevelopmentBackend(now: clock, makeDevelopmentUserOrganizer: LaunchOptions.organizer)
        let stubs = LaunchOptions.stubProviders
        let apple: AppleAuthorizing = stubs ? StubAppleAuthorizer() : SystemAppleAuthorizer()
        let auth = await DevelopmentAuthService(backend: backend, apple: apple, startSignedIn: LaunchOptions.startSignedIn)
        let authenticator: LocalAuthenticator = switch LaunchOptions.biometricOutcome {
        case "success"?: StubLocalAuthenticator(outcome: .success)
        case "failure"?: StubLocalAuthenticator(outcome: .failed)
        default: stubs ? StubLocalAuthenticator(outcome: .success) : SystemLocalAuthenticator()
        }
        let scanner: ScannerProviding = stubs || LaunchOptions.stubScannerCode != nil
            ? StubScannerProvider(code: LaunchOptions.stubScannerCode ?? "ZN-TEST-0001") : CameraScannerProvider()
        await ImagePipeline.shared.configure(source: URLImageDataSource())
        let preferences = AppPreferences()
        if LaunchOptions.skipOnboarding || LaunchOptions.startSignedIn { preferences.hasCompletedOnboarding = true }
        if LaunchOptions.forceLight { preferences.appearance = .light }
        return AppEnvironment(
            configuration: configuration, backend: .development, auth: auth, events: backend, registrations: backend,
            checkout: backend, wallet: backend, tickets: backend, profiles: backend, notifications: backend,
            organizer: backend, checkIn: backend, appleAuthorizer: apple, biometrics: BiometricGate(authenticator: authenticator),
            scanner: scanner, preferences: preferences, clock: clock
        )
    }
    #endif
}

/// Production build without Supabase configuration: every call fails clearly; the UI
/// shows a configuration error instead of fake data.
struct UnconfiguredBackend: AuthService, EventRepository, RegistrationRepository, CheckoutRepository, WalletRepository,
    TicketRepository, ProfileRepository, NotificationRepository, OrganizerRepository, CheckInRepository {
    func authEvents() -> AsyncStream<AuthSnapshot> {
        AsyncStream { $0.yield(AuthSnapshot(user: nil, event: .initial)); $0.finish() }
    }
    func signInWithApple(_ credential: AppleCredential) async throws { throw AuthFlowError.notConfigured }
    func signInWithGoogle() async throws { throw AuthFlowError.notConfigured }
    func signIn(email: String, password: String) async throws { throw AuthFlowError.notConfigured }
    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome { throw AuthFlowError.notConfigured }
    func resendConfirmation(email: String) async throws { throw AuthFlowError.notConfigured }
    func sendPasswordReset(email: String) async throws { throw AuthFlowError.notConfigured }
    func updatePassword(_ newPassword: String) async throws { throw AuthFlowError.notConfigured }
    func handle(url: URL) async -> Bool { false }
    func signOut() async {}
    func deleteAccount() async throws { throw ZunoError.notConfigured }
    func linkedIdentities() async throws -> [LinkedIdentity] { [] }
    func linkApple(_ credential: AppleCredential) async throws { throw AuthFlowError.notConfigured }
    func linkGoogle() async throws { throw AuthFlowError.notConfigured }
    func addEmailPassword(email: String, password: String) async throws { throw AuthFlowError.notConfigured }
    func unlink(_ identity: LinkedIdentity) async throws { throw AuthFlowError.notConfigured }

    func categories() async throws -> [EventCategory] { EventCategory.defaults }
    func searchEvents(query: String?, filters: EventFilters, limit: Int) async throws -> [EventSummary] { throw ZunoError.notConfigured }
    func eventDetail(id: UUID) async throws -> EventDetail { throw ZunoError.notConfigured }
    func savedEventIDs() async throws -> Set<UUID> { [] }
    func setSaved(_ saved: Bool, eventID: UUID) async throws { throw ZunoError.notConfigured }
    func savedEvents() async throws -> [EventSummary] { [] }
    func followedOrganizerIDs() async throws -> Set<UUID> { [] }
    func setFollowing(_ following: Bool, organizerID: UUID) async throws { throw ZunoError.notConfigured }
    func quoteFreeRegistration(eventID: UUID) async throws -> FreeRegistrationQuote { throw ZunoError.notConfigured }
    func registerFree(eventID: UUID, answers: [RegistrationAnswer], expectedFee: Money, idempotencyKey: String) async throws -> RegistrationConfirmation { throw ZunoError.notConfigured }
    func joinWaitlist(eventID: UUID) async throws -> WaitlistConfirmation { throw ZunoError.notConfigured }
    func cancelRegistration(id: UUID) async throws { throw ZunoError.notConfigured }
    func registrations() async throws -> [RegistrationRecord] { [] }
    func createCheckout(_ request: CheckoutRequest) async throws -> CheckoutSession { throw ZunoError.notConfigured }
    func order(id: UUID) async throws -> OrderSnapshot { throw ZunoError.notConfigured }
    #if DEBUG
    func simulateGatewayNotification(orderID: UUID, statusCode: Int) async throws { throw ZunoError.notConfigured }
    #endif
    func summary() async throws -> WalletSummary { throw ZunoError.notConfigured }
    func transactions() async throws -> [WalletTransaction] { [] }
    func tickets() async throws -> [Ticket] { [] }
    func currentProfile() async throws -> UserProfile? { nil }
    func saveProfile(_ draft: ProfileDraft, markOnboardingComplete: Bool) async throws -> UserProfile { throw ZunoError.notConfigured }
    func uploadAvatar(_ jpegData: Data) async throws -> String { throw ZunoError.notConfigured }
    func submitNationalIdentifier(_ value: String) async throws -> IdentityCheckResult { throw ZunoError.notConfigured }
    func notifications() async throws -> [AppNotification] { [] }
    func markRead(ids: [UUID]) async throws {}
    func markAllRead() async throws {}
    func preferences() async throws -> NotificationPreferences { NotificationPreferences() }
    func updatePreferences(_ preferences: NotificationPreferences) async throws {}
    func registerPushToken(_ token: String, environment: String) async throws {}
    func changes() async -> AsyncStream<Void> { AsyncStream { $0.finish() } }
    func dashboard() async throws -> OrganizerDashboard? { nil }
    func createOrganizerProfile(_ draft: OrganizerProfileDraft) async throws -> OrganizerProfile { throw ZunoError.notConfigured }
    func venues() async throws -> [Venue] { [] }
    func createVenue(name: String, addressLine: String, city: String) async throws -> Venue { throw ZunoError.notConfigured }
    func saveEventDraft(_ draft: EventDraft) async throws -> EventDraft { throw ZunoError.notConfigured }
    func eventDraft(id: UUID) async throws -> EventDraft { throw ZunoError.notConfigured }
    func uploadEventImage(eventID: UUID, organizerID: UUID, jpegData: Data) async throws -> String { throw ZunoError.notConfigured }
    func submitForPublish(eventID: UUID) async throws { throw ZunoError.notConfigured }
    func stats(eventID: UUID) async throws -> OrganizerEventStats { throw ZunoError.notConfigured }
    func attendees(eventID: UUID) async throws -> [AttendeeRow] { [] }
    func settlements() async throws -> [SettlementRow] { [] }
    func sendUpdate(eventID: UUID, kind: EventUpdateKind, message: String) async throws -> Int { throw ZunoError.notConfigured }
    func exportAttendees(eventID: UUID) async throws -> ExportedFile { throw ZunoError.notConfigured }
    func generateDraft(eventID: UUID, kind: AIDraftKind, instructions: String?) async throws -> AIDraftResult { throw ZunoError.notConfigured }
    func resolveDraft(id: UUID, approved: Bool) async throws {}
    func checkIn(eventID: UUID, code: String) async throws -> CheckInOutcome { throw ZunoError.notConfigured }
}
