import Foundation

/// Build-time configuration injected from xcconfig → Info.plist. Only publishable values
/// are ever present in the app bundle.
struct AppConfiguration: Sendable {
    enum Environment: String, Sendable { case development, test, production }

    let environment: Environment
    let supabaseURL: URL?
    let supabasePublishableKey: String?
    let oauthRedirectURL: URL
    let googleClientID: String?
    let payHereMode: String
    let payHereReturnHost: String?
    let aiFunctionName: String
    let pushEnvironment: String

    var isSupabaseConfigured: Bool { supabaseURL != nil && supabasePublishableKey != nil }

    static let current = AppConfiguration(bundle: .main)

    init(bundle: Bundle) {
        func value(_ key: String) -> String? {
            guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Unresolved build settings appear as "$(NAME)"; treat them as missing.
            return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
        }
        environment = Environment(rawValue: value("ZunoEnvironment") ?? "") ?? .development
        if let host = value("ZunoSupabaseHost") {
            let scheme = host.hasPrefix("127.0.0.1") || host.hasPrefix("localhost") ? "http" : "https"
            supabaseURL = URL(string: "\(scheme)://\(host)")
        } else {
            supabaseURL = nil
        }
        supabasePublishableKey = value("ZunoSupabasePublishableKey")
        oauthRedirectURL = URL(string: value("ZunoOAuthRedirectURL") ?? "zuno://auth/callback")!
        googleClientID = value("ZunoGoogleClientID")
        payHereMode = value("ZunoPayHereMode") ?? "sandbox"
        payHereReturnHost = value("ZunoPayHereReturnHost")
        aiFunctionName = value("ZunoAIFunctionName") ?? "ai-organizer-copilot"
        pushEnvironment = value("ZunoPushEnvironment") ?? "development"
    }

    init(environment: Environment, supabaseURL: URL?, supabasePublishableKey: String?) {
        self.environment = environment
        self.supabaseURL = supabaseURL
        self.supabasePublishableKey = supabasePublishableKey
        oauthRedirectURL = URL(string: "zuno://auth/callback")!
        googleClientID = nil
        payHereMode = "sandbox"
        payHereReturnHost = nil
        aiFunctionName = "ai-organizer-copilot"
        pushEnvironment = "development"
    }
}

/// Launch arguments used by UI tests and simulator review. They only have an effect in
/// DEBUG builds; Production builds ignore them entirely.
enum LaunchOptions {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    #if DEBUG
    /// Use the in-memory development backend even if Supabase is configured.
    static var useDevelopmentBackend: Bool { arguments.contains("-zuno-dev-backend") }
    /// Reset persisted local state (onboarding flag, caches) at launch.
    static var resetState: Bool { arguments.contains("-zuno-reset") }
    /// Start signed in as the development user.
    static var startSignedIn: Bool { arguments.contains("-zuno-signed-in") }
    /// Skip onboarding.
    static var skipOnboarding: Bool { arguments.contains("-zuno-skip-onboarding") }
    /// Deterministic provider stubs for Apple, Google, biometrics and the camera.
    static var stubProviders: Bool { arguments.contains("-zuno-stub-providers") }
    /// Force biometric gate outcome: "success" or "failure".
    static var biometricOutcome: String? { value(after: "-zuno-biometric") }
    /// Code the stub scanner "detects" after a short delay.
    static var stubScannerCode: String? { value(after: "-zuno-scanner-code") }
    /// Open a tab at launch: home, calendar, tickets, profile.
    static var initialTab: String? { value(after: "-zuno-tab") }
    /// Present a screen at launch for screenshot review.
    static var screen: String? { value(after: "-zuno-screen") }
    /// Force a light appearance for review.
    static var forceLight: Bool { arguments.contains("-zuno-light") }
    /// Make the development user an organizer.
    static var organizer: Bool { arguments.contains("-zuno-organizer") }
    /// Fixed "now" for deterministic screenshots: ISO-8601.
    static var fixedNow: Date? { value(after: "-zuno-now").flatMap { try? Date($0, strategy: .iso8601) } }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    #endif
}
