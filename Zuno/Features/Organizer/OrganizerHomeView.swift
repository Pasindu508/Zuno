import SwiftUI

struct OrganizerHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var dashboard: Loadable<OrganizerDashboard?> = .idle
    @State private var draft = OrganizerProfileDraft()
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        Group {
            switch dashboard {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let error):
                ErrorStateView(error: error) { Task { await load() } }
            case .loaded(let value):
                if let value { content(value) } else { createProfile }
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Organizer"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await load() }
        .refreshable { await load() }
        .zunoContainer("organizer.home")
    }

    private func load() async {
        if dashboard.value == nil { dashboard = .loading }
        do { dashboard = .loaded(try await environment.organizer.dashboard()) } catch { dashboard = .failed(error) }
    }

    // MARK: Create organizer profile

    private var createProfile: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Host events on Zuno").zunoDisplay(.detailTitle).foregroundStyle(.zunoPrimary)
                Text("Create an organizer profile. Our team verifies new organizers before their first event goes live — usually within two working days.")
                    .font(.body).foregroundStyle(.zunoSecondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Organizer name").font(.headline).foregroundStyle(.zunoPrimary)
                    TextField("e.g. Colombo Builders Collective", text: $draft.name)
                        .padding(14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                        .accessibilityIdentifier("organizer.name")
                    Text("About").font(.headline).foregroundStyle(.zunoPrimary)
                    TextField("What kind of events do you run?", text: $draft.bio, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                        .accessibilityIdentifier("organizer.bio")
                    Text("Contact email").font(.headline).foregroundStyle(.zunoPrimary)
                    TextField("team@example.lk", text: $draft.contactEmail)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .padding(14).background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                        .accessibilityIdentifier("organizer.email")
                }
                SurfaceCard {
                    Label("Event creation fee", systemImage: "banknote").font(.headline).foregroundStyle(.zunoPrimary)
                    Text("Each published event has a one-time fee of LKR 1,000.00, paid with PayHere before publishing. Paid tickets carry a 5% platform commission, deducted from your settlement.")
                        .font(.footnote).foregroundStyle(.zunoSecondary)
                }
                if let error { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
            }
            .padding(ZunoMetrics.margin)
            .readableWidth()
        }
        .safeAreaInset(edge: .bottom) {
            BottomActionBar {
                Button("Create organizer profile") {
                    Task {
                        creating = true
                        defer { creating = false }
                        do {
                            _ = try await environment.organizer.createOrganizerProfile(draft)
                            await load()
                        } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                    }
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: creating))
                .disabled(!draft.isValid || creating)
                .accessibilityIdentifier("organizer.create")
            }
        }
    }

    // MARK: Dashboard

    private func content(_ dashboard: OrganizerDashboard) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 8) {
                    Text(dashboard.organizer.name).zunoDisplay(.cardTitle).foregroundStyle(.zunoPrimary)
                    if dashboard.organizer.verification == .verified {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.zunoAmber).accessibilityLabel(Text("Verified"))
                    }
                }
                if dashboard.organizer.verification != .verified {
                    SurfaceCard {
                        Label(dashboard.organizer.verification.label, systemImage: "hourglass").font(.headline).foregroundStyle(.zunoPrimary)
                        Text("You can prepare drafts now. Publishing unlocks once Zuno verifies your organizer profile.")
                            .font(.footnote).foregroundStyle(.zunoSecondary)
                    }
                    .zunoContainer("organizer.pending")
                }

                FinancialsGate {
                    SurfaceCard {
                        Text("Sales").font(.headline).foregroundStyle(.zunoPrimary)
                        DetailLine(title: Text("Gross ticket sales"), value: ZunoFormat.currency(dashboard.totals.gross))
                        DetailLine(title: Text("Zuno commission (5%)"), value: ZunoFormat.currency(-dashboard.totals.commission))
                        DetailLine(title: Text("Your net"), value: ZunoFormat.currency(dashboard.totals.net), emphasized: true)
                        Button("Settlements") { router.open(.settlements) }
                            .buttonStyle(SecondaryCapsuleButtonStyle())
                    }
                }

                Button {
                    router.open(.organizerEditor(nil))
                } label: {
                    Label("Create event", systemImage: "plus")
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
                .accessibilityIdentifier("organizer.newEvent")

                SectionHeader(title: Text("Your events"))
                if dashboard.events.isEmpty {
                    Text("No events yet. Create your first one.").font(.callout).foregroundStyle(.zunoSecondary)
                }
                ForEach(dashboard.events) { row in
                    Button { router.open(.organizerEvent(row.id)) } label: { OrganizerEventRowView(row: row) }
                        .buttonStyle(CardPressStyle())
                        .accessibilityIdentifier("organizer.event")
                }
            }
            .padding(ZunoMetrics.margin)
            .readableWidth()
        }
    }
}

struct OrganizerEventRowView: View {
    let row: OrganizerEventRow

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(reference: row.event.cover)
                .frame(width: 70, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(row.event.title).zunoDisplay(.compact).foregroundStyle(.zunoPrimary).lineLimit(1)
                Text(ZunoFormat.eventDateLine(start: row.event.startsAt, end: row.event.endsAt)).font(.footnote).foregroundStyle(.zunoSecondary)
                HStack(spacing: 10) {
                    EventStatusBadge(status: row.event.status)
                    Text("\(row.registrations)/\(row.event.capacity) registered").font(.caption).foregroundStyle(.zunoSecondary)
                    Text("\(row.checkedIn) in").font(.caption).foregroundStyle(.zunoSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.zunoTertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
        .accessibilityElement(children: .combine)
    }
}

struct EventStatusBadge: View {
    let status: EventStatus
    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == .published ? ZunoColor.onSelectedFill : ZunoColor.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(status == .published ? ZunoColor.selectedFill : ZunoColor.surfaceRaised))
    }
    private var label: String {
        switch status {
        case .draft: String(localized: "Draft")
        case .pendingReview: String(localized: "In review")
        case .published: String(localized: "Published")
        case .cancelled: String(localized: "Cancelled")
        case .completed: String(localized: "Completed")
        }
    }
}

/// Inline biometric gate for organizer financial data.
struct FinancialsGate<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(BiometricGate.self) private var biometrics
    @State private var unlocked = false

    var body: some View {
        if unlocked || !biometrics.requiresUnlock(.organizerFinancials) {
            content
        } else {
            Button {
                Task { unlocked = await biometrics.authorize(.organizerFinancials) }
            } label: {
                Label("Unlock sales and settlements", systemImage: biometrics.availableKind.symbolName)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(SecondaryCapsuleButtonStyle())
            .accessibilityIdentifier("organizer.unlockFinancials")
        }
    }
}

struct SettlementsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var rows: [SettlementRow] = []

    var body: some View {
        BiometricGatedView(purpose: .organizerFinancials) {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.body.weight(.semibold)).foregroundStyle(.zunoPrimary)
                    DetailLine(title: Text("Gross"), value: ZunoFormat.currency(row.gross))
                    DetailLine(title: Text("Commission"), value: ZunoFormat.currency(-row.commission))
                    DetailLine(title: Text("Net"), value: ZunoFormat.currency(row.net), emphasized: true)
                    Text(row.payoutStatus.label).font(.caption.weight(.semibold)).foregroundStyle(.zunoSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(ZunoColor.surface)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if rows.isEmpty {
                    EmptyStateView(symbol: "banknote", title: Text("No paid sales yet"),
                                   message: Text("Settlements for paid events appear here after the event."))
                }
            }
            .task { rows = (try? await environment.organizer.settlements()) ?? [] }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Settlements"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
