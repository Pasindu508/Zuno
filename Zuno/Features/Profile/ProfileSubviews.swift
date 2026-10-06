import SwiftUI

struct SavedEventsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var events: Loadable<[EventSummary]> = .idle

    var body: some View {
        Group {
            switch events {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let list):
                if list.isEmpty {
                    EmptyStateView(symbol: "heart", title: Text("No saved events"),
                                   message: Text("Tap the heart on any event to keep it here and in your calendar."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: ZunoMetrics.cardSpacing) {
                            ForEach(list) { event in
                                NavigationLink(value: AppRoute.event(event.id)) { EventCard(event: event, now: environment.now) }
                                    .buttonStyle(CardPressStyle())
                            }
                        }
                        .padding(ZunoMetrics.margin)
                        .readableWidth()
                    }
                }
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Saved events"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        if events.value == nil { events = .loading }
        do { events = .loaded(try await environment.events.savedEvents()) } catch { events = .failed(error) }
    }
}

struct RegistrationHistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var records: Loadable<[RegistrationRecord]> = .idle

    var body: some View {
        Group {
            switch records {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error): ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let list):
                if list.isEmpty {
                    EmptyStateView(symbol: "clock", title: Text("No registrations yet"),
                                   message: Text("Every registration, waitlist and cancellation is listed here."))
                } else {
                    List(list) { record in
                        NavigationLink(value: AppRoute.event(record.event.id)) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.event.title).zunoDisplay(.compact).foregroundStyle(.zunoPrimary)
                                Text(ZunoFormat.eventDateLine(start: record.event.startsAt, end: record.event.endsAt))
                                    .font(.footnote).foregroundStyle(.zunoSecondary)
                                HStack(spacing: 8) {
                                    Text(statusLabel(record.status)).font(.caption.weight(.semibold)).foregroundStyle(.zunoPrimary)
                                    Text(record.reference).font(ZunoFont.mono(.caption)).foregroundStyle(.zunoTertiary)
                                    if record.fee.minorUnits > 0 {
                                        Text(ZunoFormat.currency(record.fee)).font(.caption).foregroundStyle(.zunoAmber)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(ZunoColor.surface)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Registration history"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func statusLabel(_ status: RegistrationStatus) -> String {
        switch status {
        case .confirmed: String(localized: "Confirmed")
        case .waitlisted: String(localized: "Waitlisted")
        case .offered: String(localized: "Place offered")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    private func load() async {
        if records.value == nil { records = .loading }
        do { records = .loaded(try await environment.registrations.registrations()) } catch { records = .failed(error) }
    }
}

/// Linked sign-in providers. Linking and unlinking require fresh local authentication;
/// accounts are never merged by matching email strings — only the Supabase user ID counts.
struct LinkedAccountsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(BiometricGate.self) private var biometrics
    @State private var identities: [LinkedIdentity] = []
    @State private var loading = true
    @State private var message: String?
    @State private var working: AuthProviderKind?
    @State private var showAddEmail = false
    @State private var pendingUnlink: LinkedIdentity?

    var body: some View {
        List {
            Section {
                ForEach(identities) { identity in
                    HStack(spacing: 14) {
                        Image(systemName: identity.provider.symbolName).frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(identity.provider.title).foregroundStyle(.zunoPrimary)
                            if let email = identity.email { Text(email).font(.footnote).foregroundStyle(.zunoSecondary) }
                        }
                        Spacer()
                        if identities.count > 1 {
                            Button("Remove", role: .destructive) { pendingUnlink = identity }
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Linked to your account")
            } footer: {
                Text("You can remove a method only while another one remains, so you never lose access.")
            }
            .listRowBackground(ZunoColor.surface)

            Section("Add a sign-in method") {
                if !has(.apple) {
                    Button { Task { await link(.apple) } } label: { Label("Link Apple", systemImage: "apple.logo") }
                }
                if !has(.google) {
                    Button { Task { await link(.google) } } label: { Label("Link Google", systemImage: "globe") }
                }
                if !has(.email) {
                    Button { Task { if await biometrics.authorize(.identityLinking) { showAddEmail = true } } } label: {
                        Label("Add email and password", systemImage: "envelope")
                    }
                }
            }
            .foregroundStyle(.zunoPrimary)
            .listRowBackground(ZunoColor.surface)
            .disabled(working != nil)

            if let message {
                Section { Text(message).font(.footnote).foregroundStyle(.zunoSecondary) }
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ZunoColor.background)
        .overlay { if loading { ProgressView() } }
        .navigationTitle(Text("Sign-in methods"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(Text("Remove this sign-in method?"), isPresented: Binding(get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }),
                            titleVisibility: .visible, presenting: pendingUnlink) { identity in
            Button("Remove \(identity.provider.title)", role: .destructive) { Task { await unlink(identity) } }
        }
        .sheet(isPresented: $showAddEmail, onDismiss: { Task { await load() } }) { AddEmailPasswordSheet() }
        .zunoContainer("linked.view")
    }

    private func has(_ provider: AuthProviderKind) -> Bool { identities.contains { $0.provider == provider } }

    private func load() async {
        loading = true
        defer { loading = false }
        do { identities = try await environment.auth.linkedIdentities() } catch {
            message = (error as? LocalizedError)?.errorDescription
        }
    }

    private func link(_ provider: AuthProviderKind) async {
        guard await biometrics.authorize(.identityLinking) else { message = biometrics.lastMessage; return }
        working = provider
        defer { working = nil }
        do {
            switch provider {
            case .apple:
                let credential = try await environment.appleAuthorizer.authorize(requestNameAndEmail: false)
                try await environment.auth.linkApple(credential)
            case .google:
                try await environment.auth.linkGoogle()
            case .email:
                return
            }
            message = String(localized: "\(provider.title) is now linked.")
            await load()
        } catch let error as AuthFlowError where error.isCancellation {
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func unlink(_ identity: LinkedIdentity) async {
        guard await biometrics.authorize(.identityLinking) else { message = biometrics.lastMessage; return }
        do {
            try await environment.auth.unlink(identity)
            message = String(localized: "\(identity.provider.title) was removed.")
            await load()
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct AddEmailPasswordSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                SecureField("Password", text: $password).textContentType(.newPassword)
                if let error { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
                Button("Add") {
                    Task {
                        do {
                            try await environment.auth.addEmailPassword(email: email, password: password)
                            dismiss()
                        } catch {
                            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        }
                    }
                }
                .disabled(!email.contains("@") || !PasswordPolicy.isAcceptable(password))
            }
            .navigationTitle(Text("Add email sign-in"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { email = session.user?.email ?? "" }
        }
        .presentationDetents([.medium])
    }
}

struct LanguageSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        Task { await choose(language) }
                    } label: {
                        HStack {
                            Text(verbatim: language.nativeName).foregroundStyle(.zunoPrimary)
                            Spacer()
                            if session.profile?.language == language { Image(systemName: "checkmark").foregroundStyle(.zunoAmber) }
                        }
                    }
                }
            } footer: {
                Text("Your choice is saved to your profile so organizer messages and emails can use it. To change the app's display language, open Settings › Apps › Zuno › Language. Sinhala and Tamil translations are being prepared.")
            }
            .listRowBackground(ZunoColor.surface)
            Section {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            .listRowBackground(ZunoColor.surface)
        }
        .scrollContentBackground(.hidden)
        .background(ZunoColor.background)
        .navigationTitle(Text("Language"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choose(_ language: AppLanguage) async {
        guard let profile = session.profile else { return }
        var draft = ProfileDraft(profile: profile)
        draft.language = language
        if let saved = try? await environment.profiles.saveProfile(draft, markOnboardingComplete: true) {
            session.profileUpdated(saved)
        }
    }
}

struct AppearanceSettingsView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        List {
            Section {
                ForEach(AppearancePreference.allCases) { option in
                    Button {
                        preferences.appearance = option
                    } label: {
                        HStack {
                            Text(option.title).foregroundStyle(.zunoPrimary)
                            Spacer()
                            if preferences.appearance == option { Image(systemName: "checkmark").foregroundStyle(.zunoAmber) }
                        }
                    }
                }
            } footer: {
                Text("Zuno is designed dark first, like a gallery after hours. The light appearance keeps the same palette with roles reversed.")
            }
            .listRowBackground(ZunoColor.surface)
        }
        .scrollContentBackground(.hidden)
        .background(ZunoColor.background)
        .navigationTitle(Text("Appearance"))
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: preferences.appearance)
    }
}

struct AccessibilitySettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            Section {
                status("Reduce Motion", on: reduceMotion, detail: "Transitions become short fades; shimmer and settling stop.")
                status("Reduce Transparency", on: reduceTransparency, detail: "Glass controls switch to solid charcoal.")
                status("Increase Contrast", on: contrast == .increased, detail: "Secondary text and dividers become stronger.")
                status("Larger Text", on: dynamicTypeSize >= .accessibility1, detail: "Display titles switch to a readable serif at the largest sizes.")
            } header: {
                Text("Zuno follows your system settings")
            } footer: {
                Text("Change these in Settings › Accessibility. Your event accessibility needs (step-free access, sign language and more) live in Edit profile.")
            }
            .listRowBackground(ZunoColor.surface)
            Section {
                Button("Open Accessibility Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            .listRowBackground(ZunoColor.surface)
        }
        .scrollContentBackground(.hidden)
        .background(ZunoColor.background)
        .navigationTitle(Text("Accessibility"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func status(_ title: LocalizedStringKey, on: Bool, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.zunoPrimary)
                Spacer()
                Text(on ? "On" : "Off").foregroundStyle(on ? ZunoColor.amber : ZunoColor.textSecondary)
            }
            Text(detail).font(.footnote).foregroundStyle(.zunoSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PrivacyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your privacy").zunoDisplay(.detailTitle).foregroundStyle(.zunoPrimary)
                item("What we collect", "Your name, email, city, interests, optional accessibility needs, registrations, tickets, wallet transactions and organizer answers you give.")
                item("NIC numbers", "Sent once to a protected server function that stores only a keyed one-way fingerprint for duplicate prevention. The number itself is never stored or logged.")
                item("Payments", "Card details go directly to PayHere. Zuno never sees or stores them, and tickets are issued only after PayHere confirms payment to our server.")
                item("Location", "Only used, with your permission, to pick the nearest city. It isn't stored.")
                item("Camera", "Only used by organizers while scanning tickets.")
                item("On this device", "Issued tickets are cached with iOS data protection so they work offline. Sign-in tokens are kept in the Keychain. Signing out removes them.")
                item("Deleting your data", "Delete your account from Profile. Profile, saved events, notifications, linked sign-in methods and your NIC fingerprint are deleted; legally required financial records are anonymised.")
                Link("Read the full privacy policy", destination: URL(string: "https://zuno.lk/privacy")!)
                    .foregroundStyle(.zunoPrimary)
            }
            .padding(ZunoMetrics.margin)
            .readableWidth()
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Privacy"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func item(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.zunoPrimary)
            Text(body).font(.callout).foregroundStyle(.zunoSecondary)
        }
    }
}
