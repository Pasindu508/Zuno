import SwiftUI
import UserNotifications

@main
struct ZunoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            AppRootView(bootstrap: bootstrap)
        }
    }
}

/// Builds the environment asynchronously (Keychain session restore, development seed).
@MainActor
@Observable
final class AppBootstrap {
    private(set) var environment: AppEnvironment?
    private(set) var session: SessionStore?
    private(set) var router = AppRouter()

    func start() async {
        guard environment == nil else { return }
        let environment = await AppEnvironment.bootstrap()
        let session = SessionStore(environment: environment)
        PushRegistrar.shared.environment = environment
        #if DEBUG
        if let tab = LaunchOptions.initialTab.flatMap(MainTab.init(rawValue:)) { router.selectedTab = tab }
        #endif
        self.environment = environment
        self.session = session
        session.start()
    }
}

struct AppRootView: View {
    let bootstrap: AppBootstrap
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let environment = bootstrap.environment, let session = bootstrap.session {
                RootRouterView()
                    .environment(environment)
                    .environment(session)
                    .environment(bootstrap.router)
                    .environment(environment.biometrics)
                    .environment(environment.preferences)
                    .environment(environment.network)
                    .preferredColorScheme(colorScheme(environment.preferences.appearance))
                    .onOpenURL { url in
                        Task { await handle(url: url, environment: environment) }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .background { environment.biometrics.lock() }
                    }
            } else {
                SplashView()
                    .preferredColorScheme(.dark)
            }
        }
        .task { await bootstrap.start() }
    }

    private func colorScheme(_ preference: AppearancePreference) -> ColorScheme? {
        switch preference {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }

    /// `zuno://auth/callback` (email confirmation, password recovery) and
    /// `zuno://payments/return` (informational; payment truth comes from the server).
    private func handle(url: URL, environment: AppEnvironment) async {
        if url.host == "auth" {
            _ = await environment.auth.handle(url: url)
        } else if url.host == "payments" {
            NotificationCenter.default.post(name: .zunoPaymentReturn, object: url)
        }
    }
}

extension Notification.Name {
    static let zunoPaymentReturn = Notification.Name("lk.zuno.payment-return")
}

struct RootRouterView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ZunoColor.background.ignoresSafeArea()
            switch session.route {
            case .launching: SplashView().transition(.opacity)
            case .onboarding: OnboardingView().transition(.opacity)
            case .auth: AuthView(presentation: .root).transition(.opacity)
            case .profileSetup: ProfileSetupView().transition(.opacity)
            case .identitySetup: IdentitySetupView(presentation: .onboarding).transition(.opacity)
            case .main: MainTabView().transition(.opacity)
            case .configurationError: ConfigurationErrorView().transition(.opacity)
            }
        }
        .animation(ZunoMotion.adaptive(.easeInOut(duration: 0.35), reduceMotion: reduceMotion), value: session.route)
    }
}

/// Dark branded splash shown while the session restores (matches the launch screen).
struct SplashView: View {
    var body: some View {
        ZStack {
            ZunoColor.background.ignoresSafeArea()
            ZunoWordmark(size: 52)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zuno is loading"))
    }
}

struct ZunoWordmark: View {
    var size: CGFloat = 44
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(verbatim: "Zuno")
                .font(ZunoFont.display(size, relativeTo: .largeTitle))
                .foregroundStyle(.zunoPrimary)
            Circle()
                .fill(ZunoColor.amber)
                .frame(width: size * 0.16, height: size * 0.16)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "Zuno"))
    }
}

struct ConfigurationErrorView: View {
    var body: some View {
        StateMessageView(
            symbol: "wifi.slash",
            title: Text("Zuno isn't configured"),
            message: Text("This build has no server configuration. Add the Supabase host and publishable key to Config/Secrets.Production.xcconfig and rebuild."),
            action: nil
        )
    }
}

// MARK: - Push notifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await PushRegistrar.shared.upload(token: token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in the simulator and without the Push capability configured.
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Requests notification permission only after the user opts in from Settings,
/// then uploads the APNs token to `push_devices`.
@MainActor
final class PushRegistrar {
    static let shared = PushRegistrar()
    weak var environment: AppEnvironment?

    func requestAuthorizationAndRegister() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func upload(token: String) async {
        guard let environment else { return }
        try? await environment.notifications.registerPushToken(token, environment: environment.configuration.pushEnvironment)
    }
}
