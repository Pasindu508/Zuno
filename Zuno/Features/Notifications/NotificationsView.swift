import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class NotificationsModel {
    var items: Loadable<[AppNotification]> = .idle

    func load(environment: AppEnvironment) async {
        if items.value == nil { items = .loading }
        do { items = .loaded(try await environment.notifications.notifications()) } catch {
            if items.value == nil { items = .failed(error) }
        }
    }

    func markRead(_ notification: AppNotification, environment: AppEnvironment) async {
        guard notification.isUnread else { return }
        update { $0.id == notification.id }
        try? await environment.notifications.markRead(ids: [notification.id])
    }

    func markAllRead(environment: AppEnvironment) async {
        update { _ in true }
        try? await environment.notifications.markAllRead()
    }

    private func update(_ predicate: (AppNotification) -> Bool) {
        guard var list = items.value else { return }
        for index in list.indices where predicate(list[index]) && list[index].readAt == nil { list[index].readAt = .now }
        items = .loaded(list)
    }
}

struct NotificationsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var model = NotificationsModel()

    var body: some View {
        Group {
            switch model.items {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await model.load(environment: environment) } }
            case .loaded(let items):
                if items.isEmpty {
                    EmptyStateView(symbol: "bell", title: Text("You're all caught up"),
                                   message: Text("Registration confirmations, payment updates, reminders and event changes will appear here."))
                } else {
                    list(items)
                }
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { router.open(.notificationSettings) } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel(Text("Notification settings"))
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark all read") { Task { await model.markAllRead(environment: environment) } }
                    .disabled((model.items.value ?? []).allSatisfy { !$0.isUnread })
                    .accessibilityIdentifier("notifications.markAll")
            }
        }
        .task { await model.load(environment: environment) }
        .refreshable { await model.load(environment: environment) }
        .zunoContainer("notifications.view")
    }

    private func list(_ items: [AppNotification]) -> some View {
        let calendar = Calendar.colombo
        let today = items.filter { calendar.isDate($0.createdAt, inSameDayAs: environment.now) }
        let earlier = items.filter { !calendar.isDate($0.createdAt, inSameDayAs: environment.now) }
        return List {
            if !today.isEmpty { section(Text("Today"), today) }
            if !earlier.isEmpty { section(Text("Earlier"), earlier) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func section(_ title: Text, _ items: [AppNotification]) -> some View {
        Section {
            ForEach(items) { item in
                Button {
                    Task { await model.markRead(item, environment: environment) }
                    if let eventID = item.eventID { router.open(.event(eventID)) }
                } label: {
                    NotificationRow(notification: item)
                }
                .buttonStyle(.plain)
                .listRowBackground(ZunoColor.background)
                .listRowSeparatorTint(ZunoColor.divider)
                .swipeActions {
                    if item.isUnread {
                        Button("Mark read") { Task { await model.markRead(item, environment: environment) } }
                            .tint(Color(uiColor: ZunoPalette.charcoal))
                    }
                }
            }
        } header: {
            title.font(.subheadline.weight(.semibold)).foregroundStyle(.zunoSecondary)
        }
    }
}

struct NotificationRow: View {
    let notification: AppNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notification.kind.symbolName)
                .font(.system(size: 17, weight: .light))
                .foregroundStyle(.zunoPrimary)
                .frame(width: 40, height: 40)
                .background(Circle().fill(ZunoColor.surface))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(notification.title)
                    .font(.body.weight(notification.isUnread ? .semibold : .regular))
                    .foregroundStyle(.zunoPrimary)
                Text(notification.body).font(.subheadline).foregroundStyle(.zunoSecondary)
                Text(ZunoFormat.relative(notification.createdAt)).font(.caption).foregroundStyle(.zunoTertiary)
            }
            Spacer(minLength: 4)
            if notification.isUnread {
                Circle().fill(ZunoColor.amber).frame(width: 9, height: 9).padding(.top, 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityValue(notification.isUnread ? Text("Unread") : Text("Read"))
    }
}

struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppPreferences.self) private var preferences
    @State private var settings = NotificationPreferences()
    @State private var loaded = false
    @State private var systemStatus: UNAuthorizationStatus = .notDetermined
    @State private var showPushExplanation = false

    var body: some View {
        Form {
            Section {
                Toggle("Push notifications", isOn: Binding(get: { settings.pushEnabled }, set: { newValue in
                    if newValue && systemStatus != .authorized { showPushExplanation = true } else { settings.pushEnabled = newValue }
                }))
                if systemStatus == .denied {
                    Button("Open Settings to allow notifications") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            } footer: {
                Text("In-app notifications are always kept in the notification center. Push alerts are optional.")
            }
            Section("Notify me about") {
                Toggle("Event reminders", isOn: $settings.eventReminders)
                Toggle("Payments and receipts", isOn: $settings.paymentUpdates)
                Toggle("Venue, schedule and cancellation changes", isOn: $settings.eventChanges)
                Toggle("Waitlist movement", isOn: $settings.waitlistUpdates)
                Toggle("News from organizers I follow", isOn: $settings.organizerNews)
            }
        }
        .tint(ZunoColor.amber)
        .scrollContentBackground(.hidden)
        .background(ZunoColor.background)
        .navigationTitle(Text("Notifications"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            settings = (try? await environment.notifications.preferences()) ?? NotificationPreferences()
            systemStatus = await PushRegistrar.shared.authorizationStatus()
            loaded = true
        }
        .onChange(of: settings) { _, newValue in
            guard loaded else { return }
            Task { try? await environment.notifications.updatePreferences(newValue) }
        }
        .alert(Text("Turn on push notifications?"), isPresented: $showPushExplanation) {
            Button("Continue") {
                Task {
                    let granted = await PushRegistrar.shared.requestAuthorizationAndRegister()
                    systemStatus = await PushRegistrar.shared.authorizationStatus()
                    settings.pushEnabled = granted
                    preferences.pushPromptShown = true
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Zuno will alert you about ticket confirmations, payment results, reminders before your events and urgent changes like venue moves. You can turn this off at any time.")
        }
    }
}
