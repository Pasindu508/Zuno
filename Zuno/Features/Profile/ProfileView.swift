import SwiftUI

struct ProfileTabRoot: View {
    @Environment(AppRouter.self) private var router
    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.profilePath) {
            ProfileView()
                .navigationDestination(for: AppRoute.self) { AppDestination(route: $0, namespace: nil) }
        }
    }
}

struct ProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(BiometricGate.self) private var biometrics
    @Environment(AppPreferences.self) private var preferences
    @State private var wallet: WalletSummary?
    @State private var savedCount = 0
    @State private var confirmSignOut = false
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var appLockToggle = false

    var body: some View {
        Group {
            if session.isSignedIn, let profile = session.profile {
                content(profile)
            } else if session.isSignedIn {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                guestContent
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Profile"))
        .task(id: session.user?.id) { await loadSummary() }
        .confirmationDialog(Text("Sign out of Zuno?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                Task {
                    await session.signOut()
                    router.resetAll()
                }
            }
        } message: {
            Text("Offline tickets and cached data are removed from this device. Your account and tickets stay safe on our server.")
        }
        .sheet(isPresented: $confirmDelete) { DeleteAccountSheet() }
    }

    private var guestContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                SignInPromptView(title: Text("Make Zuno yours"),
                                 message: Text("Sign in to save events, register, keep tickets offline and manage your wallet."))
                    .frame(minHeight: 340)
                settingsGroup(Text("Preferences")) {
                    row("Appearance", symbol: "circle.lefthalf.filled", route: .appearance)
                    row("Accessibility", symbol: "accessibility", route: .accessibility)
                    row("Privacy", symbol: "hand.raised", route: .privacy)
                }
            }
            .padding(ZunoMetrics.margin)
            .readableWidth()
        }
    }

    private func content(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(profile)
                quickTiles
                settingsGroup(Text("Activity")) {
                    row("Saved events", symbol: "heart", route: .savedEvents, detail: savedCount > 0 ? "\(savedCount)" : nil)
                    row("Registration history", symbol: "clock", route: .registrationHistory)
                    row("Wallet", symbol: "wallet.bifold", route: .wallet,
                        detail: wallet.map { ZunoFormat.currency($0.balance, compact: true) })
                }
                settingsGroup(Text("Organizer")) {
                    row("Organizer mode", symbol: "megaphone", route: .organizer)
                }
                settingsGroup(Text("Account")) {
                    row("Sign-in methods", symbol: "key", route: .linkedAccounts)
                    row("Identity (NIC)", symbol: "person.crop.circle.badge.checkmark", route: .identity,
                        detail: profile.hasIdentitySetup ? String(localized: "Done") : String(localized: "Needed to register"))
                    row("Notifications", symbol: "bell", route: .notificationSettings)
                }
                settingsGroup(Text("Preferences")) {
                    row("Language", symbol: "globe", route: .language, detail: profile.language.nativeName)
                    row("Appearance", symbol: "circle.lefthalf.filled", route: .appearance, detail: preferences.appearance.title)
                    row("Accessibility", symbol: "accessibility", route: .accessibility)
                    appLockRow
                }
                settingsGroup(Text("About")) {
                    row("Privacy", symbol: "hand.raised", route: .privacy)
                    Link(destination: URL(string: "https://zuno.lk/terms")!) {
                        rowLabel("Terms of service", symbol: "doc.text", detail: nil, external: true)
                    }
                    rowLabel("Version", symbol: "iphone", detail: "\(Bundle.main.shortVersion)\(environment.isDevelopmentBackend ? " · Development data" : "")", chevron: false)
                }
                VStack(spacing: 10) {
                    Button("Sign out") { confirmSignOut = true }
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                        .accessibilityIdentifier("profile.signOut")
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                        .buttonStyle(SecondaryCapsuleButtonStyle(destructive: true))
                        .accessibilityIdentifier("profile.delete")
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.vertical, 12)
            .readableWidth()
        }
        .refreshable { await loadSummary() }
        .zunoContainer("profile.view")
    }

    private func header(_ profile: UserProfile) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(ZunoColor.selectedFill)
                if let path = profile.avatarPath {
                    ArtworkImage(reference: .storage(bucket: StorageBucket.avatars, path: path), fallbackSymbol: "person")
                        .clipShape(.circle)
                } else {
                    Text(profile.initials.isEmpty ? "Z" : profile.initials)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(ZunoColor.onSelectedFill)
                }
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.displayName)
                    .zunoDisplay(.cardTitle)
                    .foregroundStyle(.zunoPrimary)
                    .lineLimit(2)
                Label("\(profile.city ?? preferences.selectedCity), Sri Lanka", systemImage: "mappin.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.zunoSecondary)
                if let email = session.user?.email {
                    Text(email).font(.footnote).foregroundStyle(.zunoTertiary).lineLimit(1)
                }
            }
            Spacer()
            FloatingGlassIconButton(systemName: "pencil", accessibilityLabel: Text("Edit profile")) {
                router.open(.editProfile)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var quickTiles: some View {
        HStack(spacing: 12) {
            tile(title: Text("Wallet"), value: wallet.map { ZunoFormat.currency($0.balance, compact: true) } ?? "—", symbol: "wallet.bifold") {
                router.open(.wallet)
            }
            tile(title: Text("Free left"), value: wallet.map { "\($0.allowanceRemaining)/\($0.allowanceLimit)" } ?? "—", symbol: "ticket") {
                router.open(.wallet)
            }
        }
    }

    private func tile(title: Text, value: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(.zunoSecondary)
                Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.zunoPrimary).lineLimit(1).minimumScaleFactor(0.7)
                title.font(.footnote).foregroundStyle(.zunoSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
    }

    private var appLockRow: some View {
        Toggle(isOn: Binding(get: { biometrics.isAppLockEnabled }, set: { newValue in
            Task { _ = await biometrics.setAppLock(enabled: newValue) }
        })) {
            HStack(spacing: 14) {
                Image(systemName: biometrics.availableKind.symbolName)
                    .font(.system(size: 18, weight: .light))
                    .frame(width: 24)
                    .foregroundStyle(.zunoPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Lock with \(biometrics.availableKind.title)").foregroundStyle(.zunoPrimary)
                    Text("Protects wallet, ticket details and organizer tools").font(.caption).foregroundStyle(.zunoSecondary)
                }
            }
        }
        .tint(ZunoColor.amber)
        .padding(.vertical, 10)
        .accessibilityIdentifier("profile.appLock")
    }

    private func settingsGroup<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            title.font(.footnote.weight(.semibold)).foregroundStyle(.zunoSecondary).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
        }
    }

    private func row(_ title: LocalizedStringKey, symbol: String, route: AppRoute, detail: String? = nil) -> some View {
        Button { router.open(route) } label: { rowLabel(title, symbol: symbol, detail: detail) }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profile.\(String(describing: route))")
    }

    private func rowLabel(_ title: LocalizedStringKey, symbol: String, detail: String?, external: Bool = false, chevron: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .frame(width: 24)
                .foregroundStyle(.zunoPrimary)
                .accessibilityHidden(true)
            Text(title).foregroundStyle(.zunoPrimary)
            Spacer()
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.zunoSecondary).lineLimit(1) }
            if chevron {
                Image(systemName: external ? "arrow.up.right" : "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.zunoTertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 52)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private func loadSummary() async {
        guard session.isSignedIn else { return }
        wallet = try? await environment.wallet.summary()
        savedCount = (try? await environment.events.savedEventIDs().count) ?? 0
    }
}

struct DeleteAccountSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(BiometricGate.self) private var biometrics
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Delete your account").zunoDisplay(.section).foregroundStyle(.zunoPrimary)
                    Text("This permanently deletes your profile, saved events, notifications, linked sign-in methods and NIC fingerprint. Upcoming tickets are cancelled. Payment and wallet records are kept in anonymised form where Sri Lankan law requires it.")
                        .font(.callout).foregroundStyle(.zunoSecondary)
                    Text("Type DELETE to confirm.").font(.subheadline.weight(.semibold)).foregroundStyle(.zunoPrimary)
                    TextField("DELETE", text: $confirmation)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                        .accessibilityIdentifier("delete.confirmation")
                    if let error { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
                    Button("Delete account permanently", role: .destructive) { Task { await delete() } }
                        .buttonStyle(SecondaryCapsuleButtonStyle(destructive: true))
                        .disabled(confirmation != "DELETE" || working)
                        .accessibilityIdentifier("delete.submit")
                }
                .padding(20)
            }
            .background(ZunoColor.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel(Text("Close"))
                }
            }
        }
        .presentationDetents([.large])
    }

    private func delete() async {
        guard await biometrics.authorize(.accountChange) else {
            error = biometrics.lastMessage
            return
        }
        working = true
        defer { working = false }
        do {
            try await session.deleteAccount()
            router.resetAll()
            dismiss()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
