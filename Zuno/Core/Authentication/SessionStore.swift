import AuthenticationServices
import Foundation
import Observation

/// Something a guest started that needs an account; resumed after sign-in completes.
enum PendingIntent: Equatable, Sendable {
    case register(eventID: UUID)
    case saveEvent(eventID: UUID)
    case openTab(MainTab)
}

/// The single authentication-state observer. It restores the session, loads (or creates)
/// the profile and routes: onboarding → auth → profile setup → identity → main.
@MainActor
@Observable
final class SessionStore {
    enum Route: Equatable {
        case launching
        case onboarding
        case auth
        case profileSetup
        case identitySetup
        case main
        case configurationError
    }

    private(set) var route: Route = .launching
    private(set) var user: AuthUser?
    private(set) var profile: UserProfile?
    private(set) var profileLoadError: String?
    var isGuest = false
    var notice: String?
    var pendingIntent: PendingIntent?
    var isAuthSheetPresented = false
    var isPasswordRecoveryPresented = false

    private let environment: AppEnvironment
    private var listener: Task<Void, Never>?
    private static let appleUserKey = "apple-user-identifier"

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isSignedIn: Bool { user != nil }

    func start() {
        guard listener == nil else { return }
        if environment.backend == .unconfigured {
            route = .configurationError
            return
        }
        listener = Task { [weak self] in
            guard let stream = self?.environment.auth.authEvents() else { return }
            for await snapshot in stream {
                await self?.handle(snapshot)
            }
        }
    }

    private func handle(_ snapshot: AuthSnapshot) async {
        let previousUser = user
        user = snapshot.user
        switch snapshot.event {
        case .sessionExpired:
            notice = String(localized: "Your session expired. Please sign in again.")
            await clearLocalUserState()
        case .signedOut:
            if previousUser != nil { await clearLocalUserState() }
        case .passwordRecovery:
            isPasswordRecoveryPresented = true
        case .initial:
            await verifyAppleCredentialIfNeeded()
        default:
            break
        }
        if snapshot.user != nil, previousUser?.id != snapshot.user?.id || profile == nil {
            await loadProfile()
        } else if snapshot.user == nil {
            profile = nil
        }
        recomputeRoute()
    }

    /// Fetches the profile; the database trigger creates it on sign-up, but if it is
    /// missing (trigger not yet run) we create the row from what the provider shared.
    func loadProfile() async {
        guard let user else { return }
        profileLoadError = nil
        do {
            if let existing = try await environment.profiles.currentProfile() {
                profile = existing
            } else {
                var draft = ProfileDraft()
                draft.displayName = user.displayNameHint ?? ""
                draft.city = environment.preferences.selectedCity
                draft.district = SriLankaLocations.place(named: draft.city)?.district ?? draft.city
                profile = try await environment.profiles.saveProfile(draft, markOnboardingComplete: false)
            }
            if let city = profile?.city { environment.preferences.selectedCity = city }
        } catch {
            profileLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func recomputeRoute() {
        guard environment.backend != .unconfigured else { route = .configurationError; return }
        let next: Route
        if user == nil {
            if !environment.preferences.hasCompletedOnboarding { next = .onboarding }
            else { next = isGuest ? .main : .auth }
        } else if let profile {
            if !profile.isComplete { next = .profileSetup }
            else if !profile.hasIdentitySetup && !environment.preferences.identityPromptDeferred { next = .identitySetup }
            else { next = .main }
        } else {
            next = profileLoadError == nil ? .launching : .main
        }
        if next == .main, user != nil { isAuthSheetPresented = false }
        route = next
    }

    // MARK: Actions

    func completeOnboarding(browseAsGuest: Bool) {
        environment.preferences.hasCompletedOnboarding = true
        isGuest = browseAsGuest
        recomputeRoute()
    }

    func continueAsGuest() {
        isGuest = true
        recomputeRoute()
    }

    /// A guest tried something that needs an account: remember it and ask to sign in.
    func requireAccount(for intent: PendingIntent) {
        pendingIntent = intent
        isAuthSheetPresented = true
    }

    func consumePendingIntent() -> PendingIntent? {
        defer { pendingIntent = nil }
        return pendingIntent
    }

    func profileUpdated(_ profile: UserProfile) {
        self.profile = profile
        environment.preferences.selectedCity = profile.city ?? environment.preferences.selectedCity
        recomputeRoute()
    }

    func deferIdentitySetup() {
        environment.preferences.identityPromptDeferred = true
        recomputeRoute()
    }

    func identityCompleted() async {
        await loadProfile()
        recomputeRoute()
    }

    func rememberAppleUser(_ identifier: String) {
        try? Keychain.standard.set(Data(identifier.utf8), for: Self.appleUserKey)
    }

    func signOut() async {
        await environment.auth.signOut()
        await clearLocalUserState()
        user = nil
        profile = nil
        isGuest = false
        recomputeRoute()
    }

    func deleteAccount() async throws {
        try await environment.auth.deleteAccount()
        await clearLocalUserState()
        user = nil
        profile = nil
        isGuest = false
        recomputeRoute()
    }

    /// Clears sensitive local state on sign-out: offline tickets, cached images,
    /// biometric unlocks, per-user preferences and Keychain values.
    private func clearLocalUserState() async {
        await environment.ticketCache.clear()
        await ImagePipeline.shared.purge()
        environment.biometrics.reset()
        environment.preferences.clearUserState()
        Keychain.standard.remove(Self.appleUserKey)
    }

    /// Signs out locally if the user revoked Zuno's access to their Apple ID.
    private func verifyAppleCredentialIfNeeded() async {
        guard user != nil, let data = Keychain.standard.data(for: Self.appleUserKey) else { return }
        let state = await environment.appleAuthorizer.credentialState(forUserID: String(decoding: data, as: UTF8.self))
        if state == .revoked || state == .notFound {
            notice = AuthFlowError.credentialRevoked.errorDescription
            await signOut()
        }
    }
}
