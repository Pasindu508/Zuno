import SwiftUI

enum MainTab: String, Hashable, Sendable, CaseIterable {
    case home, calendar, tickets, profile
}

/// Destinations shared by every tab's navigation stack.
enum AppRoute: Hashable {
    case event(UUID)
    case notifications
    case notificationSettings
    case wallet
    case ticket(UUID)
    case savedEvents
    case registrationHistory
    case linkedAccounts
    case editProfile
    case identity
    case language
    case appearance
    case accessibility
    case privacy
    case organizer
    case organizerEvent(UUID)
    case organizerEditor(UUID?)
    case checkIn(UUID)
    case settlements
}

/// Per-tab navigation state so selection and stacks survive tab switches.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: MainTab = .home
    var homePath: [AppRoute] = []
    var calendarPath: [AppRoute] = []
    var ticketsPath: [AppRoute] = []
    var profilePath: [AppRoute] = []
    /// Set when an event should open its registration flow as soon as it appears.
    var autoRegisterEventID: UUID?

    func open(_ route: AppRoute, in tab: MainTab? = nil) {
        let target = tab ?? selectedTab
        selectedTab = target
        switch target {
        case .home: homePath.append(route)
        case .calendar: calendarPath.append(route)
        case .tickets: ticketsPath.append(route)
        case .profile: profilePath.append(route)
        }
    }

    func resetAll() {
        homePath = []
        calendarPath = []
        ticketsPath = []
        profilePath = []
        selectedTab = .home
    }
}

struct MainTabView: View {
    @Environment(AppRouter.self) private var router
    @Environment(SessionStore.self) private var session

    var body: some View {
        @Bindable var router = router
        @Bindable var session = session
        TabView(selection: $router.selectedTab) {
            Tab(value: MainTab.home) {
                HomeTabRoot()
            } label: {
                Label("Home", systemImage: "house")
            }
            .accessibilityIdentifier("tab.home")

            Tab(value: MainTab.calendar) {
                CalendarTabRoot()
            } label: {
                Label("Calendar", systemImage: "calendar")
            }
            .accessibilityIdentifier("tab.calendar")

            Tab(value: MainTab.tickets) {
                TicketsTabRoot()
            } label: {
                Label("Tickets", systemImage: "ticket")
            }
            .accessibilityIdentifier("tab.tickets")

            Tab(value: MainTab.profile) {
                ProfileTabRoot()
            } label: {
                Label("Profile", systemImage: "person")
            }
            .accessibilityIdentifier("tab.profile")
        }
        .tint(ZunoColor.textPrimary)
        .sheet(isPresented: $session.isAuthSheetPresented) {
            AuthView(presentation: .sheet)
                .presentationDetents([.large])
                .presentationBackground(ZunoColor.background)
        }
        .sheet(isPresented: $session.isPasswordRecoveryPresented) {
            PasswordRecoveryView()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: session.isSignedIn) { _, signedIn in
            guard signedIn, let intent = session.consumePendingIntent() else { return }
            resume(intent)
        }
        .task {
            if session.isSignedIn, let intent = session.consumePendingIntent() { resume(intent) }
        }
    }

    private func resume(_ intent: PendingIntent) {
        switch intent {
        case .register(let eventID):
            router.autoRegisterEventID = eventID
            if router.homePath.last != .event(eventID) { router.open(.event(eventID), in: .home) }
        case .saveEvent(let eventID):
            router.open(.event(eventID), in: .home)
        case .openTab(let tab):
            router.selectedTab = tab
        }
    }
}

/// Resolves a route to its screen. One place, so every tab can push any destination.
struct AppDestination: View {
    let route: AppRoute
    let namespace: Namespace.ID?

    var body: some View {
        switch route {
        case .event(let id):
            EventDetailView(eventID: id)
                .modifier(ZoomDestination(id: id, namespace: namespace))
        case .notifications: NotificationsView()
        case .notificationSettings: NotificationSettingsView()
        case .wallet: WalletView()
        case .ticket(let id): TicketDetailView(ticketID: id)
        case .savedEvents: SavedEventsView()
        case .registrationHistory: RegistrationHistoryView()
        case .linkedAccounts: LinkedAccountsView()
        case .editProfile: EditProfileView()
        case .identity: IdentitySetupView(presentation: .settings)
        case .language: LanguageSettingsView()
        case .appearance: AppearanceSettingsView()
        case .accessibility: AccessibilitySettingsView()
        case .privacy: PrivacyView()
        case .organizer: OrganizerHomeView()
        case .organizerEvent(let id): OrganizerEventView(eventID: id)
        case .organizerEditor(let id): EventEditorView(eventID: id)
        case .checkIn(let id): CheckInView(eventID: id)
        case .settlements: SettlementsView()
        }
    }
}

/// Applies the zoom navigation transition when a source namespace exists.
private struct ZoomDestination: ViewModifier {
    let id: UUID
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
