import MapKit
import SwiftUI

struct EventDetailView: View {
    let eventID: UUID

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = EventDetailModel()
    @State private var confirmWaitlist = false
    @State private var confirmCancel = false

    var body: some View {
        Group {
            switch model.detail {
            case .idle, .loading:
                DetailSkeleton(onBack: { dismiss() })
            case .failed(let error):
                VStack {
                    HStack {
                        FloatingGlassIconButton(systemName: "arrow.left", accessibilityLabel: Text("Back")) { dismiss() }
                        Spacer()
                    }
                    .padding(.horizontal, ZunoMetrics.margin)
                    ErrorStateView(error: error) { Task { await model.load(eventID: eventID, environment: environment) } }
                }
            case .loaded(let detail):
                content(detail)
            }
        }
        .background(ZunoColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task {
            await model.load(eventID: eventID, environment: environment)
            // Resume a registration that started before sign-in.
            if router.autoRegisterEventID == eventID, let detail = model.detail.value {
                router.autoRegisterEventID = nil
                perform(EventPrimaryAction.resolve(for: detail, now: environment.now), detail: detail)
            }
        }
        .onChange(of: session.isSignedIn) { _, _ in Task { await model.load(eventID: eventID, environment: environment) } }
        .sheet(item: $model.sheet) { sheet in
            if let detail = model.detail.value {
                switch sheet {
                case .registerFree:
                    RegistrationSheet(detail: detail) {
                        Task { await model.registrationCompleted(environment: environment) }
                    }
                case .checkout:
                    TicketCheckoutSheet(detail: detail) {
                        Task { await model.registrationCompleted(environment: environment) }
                    }
                case .addToCalendar:
                    CalendarEventEditor(event: detail.summary, notes: detail.description, url: shareURL(detail.summary))
                        .ignoresSafeArea()
                }
            }
        }
        .confirmationDialog(Text("Join the waitlist?"), isPresented: $confirmWaitlist, titleVisibility: .visible) {
            Button("Join waitlist") { Task { await model.joinWaitlist(environment: environment) } }
        } message: {
            Text("We'll notify you if a place opens. Joining is free and you can leave at any time.")
        }
        .confirmationDialog(Text("Cancel your registration?"), isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel registration", role: .destructive) { Task { await model.cancelRegistration(environment: environment) } }
        } message: {
            Text("Your place will be offered to the next person on the waitlist. Allowance and fees already used aren't returned.")
        }
        .zunoContainer("event.detail")
    }

    // MARK: Layout

    private func content(_ detail: EventDetail) -> some View {
        GeometryReader { proxy in
            if horizontalSizeClass == .regular && proxy.size.width > 860 {
                HStack(alignment: .top, spacing: 0) {
                    VStack {
                        artwork(detail, height: proxy.size.height - 24)
                    }
                    .frame(width: proxy.size.width * 0.48)
                    ScrollView {
                        information(detail)
                            .padding(.horizontal, 28)
                            .padding(.top, 20)
                            .padding(.bottom, 120)
                    }
                    .safeAreaInset(edge: .bottom) { actionBar(detail) }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        artwork(detail, height: artworkHeight(for: proxy.size))
                            .padding(.top, 4)
                        information(detail)
                            .padding(.horizontal, ZunoMetrics.margin)
                            .padding(.top, 18)
                            .padding(.bottom, 24)
                            .readableWidth()
                    }
                }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaInset(edge: .bottom) { actionBar(detail) }
            }
        }
    }

    /// ≈57 % of the screen on phones, as in the reference, but never taller than 1.35× the width.
    private func artworkHeight(for size: CGSize) -> CGFloat {
        let byHeight = size.height * 0.6
        let byWidth = (size.width - 2 * ZunoMetrics.detailArtworkInset) * 1.35
        return max(min(byHeight, byWidth), 260)
    }

    private func artwork(_ detail: EventDetail, height: CGFloat) -> some View {
        DetailArtworkHeader(
            event: detail.summary,
            isSaved: model.isSaved,
            pillText: ZunoFormat.pillText(for: detail.summary, now: environment.now),
            height: height,
            shareURL: shareURL(detail.summary),
            onBack: { dismiss() },
            onToggleSave: { model.toggleSave(environment: environment, session: session) }
        )
    }

    private func shareURL(_ event: EventSummary) -> URL {
        URL(string: "https://zuno.lk/e/\(event.id.uuidString.lowercased())")!
    }

    // MARK: Information

    @ViewBuilder
    private func information(_ detail: EventDetail) -> some View {
        let event = detail.summary
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                Text(event.title)
                    .zunoDisplay(.detailTitle)
                    .foregroundStyle(.zunoPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("detail.title")
                Text(detail.description)
                    .font(.callout)
                    .lineSpacing(5)
                    .foregroundStyle(ZunoColor.textPrimary.opacity(0.86))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let banner = model.banner {
                Label(banner, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.zunoPrimary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                    .accessibilityIdentifier("detail.banner")
            }

            facts(detail)

            if let location = event.location, event.format != .online {
                EventMapPreview(name: event.venueName ?? event.title, location: location, address: detail.addressLine)
            }

            organizer(detail)

            if !detail.tiers.isEmpty { tiers(detail.tiers) }
            if !detail.agenda.isEmpty { agenda(detail.agenda) }
            if !detail.speakers.isEmpty { speakers(detail.speakers) }
            if !detail.questions.isEmpty { questions(detail.questions) }

            if let policy = detail.refundPolicy, !policy.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: Text("Refunds and cancellation"))
                    Text(policy).font(.callout).foregroundStyle(.zunoSecondary)
                }
            }

            // Free registrations can be cancelled; paid tickets follow the refund policy.
            if detail.viewer.registrationStatus == .confirmed && event.isFree {
                Button("Cancel my registration", role: .destructive) { confirmCancel = true }
                    .buttonStyle(SecondaryCapsuleButtonStyle(destructive: true))
                    .disabled(model.isWorking)
            }

            if !model.related.isEmpty { related(model.related) }
        }
    }

    private func facts(_ detail: EventDetail) -> some View {
        let event = detail.summary
        return SurfaceCard {
            FactRow(symbol: "calendar", title: Text(ZunoFormat.longDay(event.startsAt)),
                    subtitle: Text(ZunoFormat.timeRange(start: event.startsAt, end: event.endsAt)))
            Divider().overlay(ZunoColor.divider)
            FactRow(symbol: event.format == .online ? "globe" : "mappin.and.ellipse",
                    title: Text(event.format == .online ? String(localized: "Online event") : (event.venueName ?? String(localized: "Venue to be announced"))),
                    subtitle: Text([detail.addressLine, event.city, event.format == .hybrid ? String(localized: "Also streamed online") : nil]
                        .compactMap { $0 }.joined(separator: " · ")))
            Divider().overlay(ZunoColor.divider)
            FactRow(symbol: EventCategory.symbol(for: event.categoryID), title: Text(event.categoryName),
                    subtitle: event.university.map { Text($0) } ?? Text(event.tags.prefix(3).joined(separator: " · ")))
            Divider().overlay(ZunoColor.divider)
            CapacityRow(event: event)
            Divider().overlay(ZunoColor.divider)
            FactRow(symbol: event.isFree ? "ticket" : "creditcard",
                    title: Text(event.isFree ? String(localized: "Free registration") : String(localized: "From \(ZunoFormat.priceLabel(for: event))")),
                    subtitle: Text(event.isFree ? String(localized: "15 free registrations included each month") : String(localized: "Secure payment with PayHere")))
            Button {
                model.sheet = .addToCalendar
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(SecondaryCapsuleButtonStyle())
            .accessibilityIdentifier("detail.addToCalendar")
        }
    }

    private func organizer(_ detail: EventDetail) -> some View {
        HStack(spacing: 12) {
            Text(String(detail.summary.organizerName.prefix(1)))
                .font(.headline)
                .foregroundStyle(ZunoColor.onSelectedFill)
                .frame(width: 44, height: 44)
                .background(Circle().fill(ZunoColor.selectedFill))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Organized by").font(.caption).foregroundStyle(.zunoSecondary)
                HStack(spacing: 4) {
                    Text(detail.summary.organizerName).font(.body.weight(.semibold)).foregroundStyle(.zunoPrimary)
                    if detail.organizerVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.zunoAmber)
                            .accessibilityLabel(Text("Verified organizer"))
                    }
                }
            }
            Spacer()
            Button {
                model.toggleFollow(environment: environment, session: session)
            } label: {
                Text(model.isFollowingOrganizer ? "Following" : "Follow")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 36)
                    .foregroundStyle(model.isFollowingOrganizer ? ZunoColor.textPrimary : ZunoColor.onSelectedFill)
                    .background(Capsule().fill(model.isFollowingOrganizer ? ZunoColor.surface : ZunoColor.selectedFill))
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.selection, trigger: model.isFollowingOrganizer)
        }
        .accessibilityElement(children: .combine)
    }

    private func tiers(_ tiers: [TicketTier]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Text("Tickets"))
            ForEach(tiers) { tier in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tier.name).font(.body.weight(.semibold)).foregroundStyle(.zunoPrimary)
                        if !tier.description.isEmpty {
                            Text(tier.description).font(.footnote).foregroundStyle(.zunoSecondary)
                        }
                        availabilityText(tier)
                    }
                    Spacer()
                    Text(ZunoFormat.currency(tier.price, compact: true))
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.zunoPrimary)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ZunoColor.surface))
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func availabilityText(_ tier: TicketTier) -> some View {
        switch Availability.evaluate(remaining: tier.remaining, capacity: tier.quantity) {
        case .soldOut: Text("Sold out").font(.caption.weight(.semibold)).foregroundStyle(.zunoTertiary)
        case .limited(let remaining): Text("Only \(remaining) left").font(.caption.weight(.semibold)).foregroundStyle(.zunoAmber)
        case .available(let remaining): Text("\(remaining) available").font(.caption).foregroundStyle(.zunoSecondary)
        }
    }

    private func agenda(_ items: [AgendaItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Text("Agenda"))
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 0) {
                            Circle().fill(index == 0 ? ZunoColor.amber : ZunoColor.textTertiary).frame(width: 9, height: 9).padding(.top, 6)
                            if index < items.count - 1 {
                                Rectangle().fill(ZunoColor.divider).frame(width: 1).frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: 10)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ZunoFormat.time(item.startsAt))
                                .font(ZunoFont.mono(.caption))
                                .foregroundStyle(.zunoSecondary)
                            Text(item.title).font(.body.weight(.semibold)).foregroundStyle(.zunoPrimary)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(.footnote).foregroundStyle(.zunoSecondary)
                            }
                        }
                        .padding(.bottom, 16)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func speakers(_ speakers: [Speaker]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Text("Speakers"))
            ForEach(speakers) { speaker in
                HStack(spacing: 12) {
                    Text(speaker.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.zunoPrimary)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(ZunoColor.surfaceRaised))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.name).font(.body.weight(.medium)).foregroundStyle(.zunoPrimary)
                        Text([speaker.role, speaker.organization].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.footnote).foregroundStyle(.zunoSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func questions(_ questions: [RegistrationQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: Text("When you register"))
            Text("The organizer will ask:").font(.footnote).foregroundStyle(.zunoSecondary)
            ForEach(questions) { question in
                Label {
                    Text(question.prompt + (question.required ? "" : " " + String(localized: "(optional)")))
                        .font(.callout)
                        .foregroundStyle(.zunoPrimary)
                } icon: {
                    Image(systemName: "list.bullet").foregroundStyle(.zunoTertiary)
                }
            }
        }
    }

    private func related(_ events: [EventSummary]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Text("Related events"))
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(events) { event in
                        NavigationLink(value: AppRoute.event(event.id)) {
                            VStack(alignment: .leading, spacing: 8) {
                                ArtworkImage(reference: event.cover)
                                    .frame(width: 220, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                Text(event.title).zunoDisplay(.compact).foregroundStyle(.zunoPrimary).lineLimit(1)
                                Text(ZunoFormat.eventDateLine(start: event.startsAt, end: event.endsAt))
                                    .font(.footnote).foregroundStyle(.zunoSecondary)
                            }
                            .frame(width: 220, alignment: .leading)
                        }
                        .buttonStyle(CardPressStyle())
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    // MARK: Primary action

    private func actionBar(_ detail: EventDetail) -> some View {
        let action = EventPrimaryAction.resolve(for: detail, now: environment.now)
        return BottomActionBar {
            Button {
                perform(action, detail: detail)
            } label: {
                Text(action.title)
            }
            .buttonStyle(PrimaryCapsuleButtonStyle(isLoading: model.isWorking))
            .disabled(!action.isEnabled || model.isWorking)
            .accessibilityIdentifier("detail.primaryAction")
        }
    }

    private func perform(_ action: EventPrimaryAction, detail: EventDetail) {
        guard session.isSignedIn || action == .viewTicket else {
            session.requireAccount(for: .register(eventID: detail.id))
            return
        }
        switch action {
        case .registerFree, .joinOnlineEvent: model.sheet = .registerFree
        case .buyTicket: model.sheet = .checkout
        case .joinWaitlist: confirmWaitlist = true
        case .viewTicket: router.open(.ticket(detail.id))
        case .onWaitlist, .soldOut, .registrationClosed, .eventEnded, .eventCancelled: break
        }
    }
}

// MARK: - Supporting views

struct FactRow: View {
    let symbol: String
    let title: Text
    let subtitle: Text

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.zunoPrimary)
                .frame(width: 24)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.body.weight(.medium)).foregroundStyle(.zunoPrimary)
                subtitle.font(.footnote).foregroundStyle(.zunoSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CapacityRow: View {
    let event: EventSummary
    @State private var warned = false

    var body: some View {
        let taken = max(event.capacity - event.seatsRemaining, 0)
        let fraction = event.capacity > 0 ? Double(taken) / Double(event.capacity) : 1
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "person.2")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.zunoPrimary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                switch event.availability {
                case .soldOut:
                    Text("Fully booked").font(.body.weight(.medium)).foregroundStyle(.zunoPrimary)
                case .limited(let remaining):
                    Text("Only ^[\(remaining) place](inflect: true) left").font(.body.weight(.medium)).foregroundStyle(.zunoAmber)
                case .available(let remaining):
                    Text("^[\(remaining) place](inflect: true) left").font(.body.weight(.medium)).foregroundStyle(.zunoPrimary)
                }
                ProgressView(value: fraction)
                    .tint(isLimited ? ZunoColor.amber : ZunoColor.textPrimary)
                    .accessibilityHidden(true)
                Text("Capacity \(event.capacity)").font(.footnote).foregroundStyle(.zunoSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .sensoryFeedback(.warning, trigger: warned)
        .onAppear { if isLimited { warned = true } }
    }

    private var isLimited: Bool {
        if case .limited = event.availability { return true }
        return false
    }
}

struct EventMapPreview: View {
    let name: String
    let location: GeoPoint
    let address: String?

    var body: some View {
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: Text("Location"))
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1400, longitudinalMeters: 1400)), interactionModes: []) {
                Marker(name, systemImage: "mappin", coordinate: coordinate)
                    .tint(ZunoColor.amber)
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel(Text("Map showing \(name)"))
            Button {
                let item = MKMapItem(location: CLLocation(latitude: location.latitude, longitude: location.longitude), address: nil)
                item.name = name
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
            } label: {
                Label("Get directions", systemImage: "map")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.zunoPrimary)
        }
    }
}

struct DetailSkeleton: View {
    let onBack: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ShimmerPlaceholder()
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: ZunoMetrics.detailArtworkRadius, style: .continuous))
                .padding(.horizontal, ZunoMetrics.detailArtworkInset)
                .overlay(alignment: .topLeading) {
                    FloatingGlassIconButton(systemName: "arrow.left", accessibilityLabel: Text("Back"), placement: .onMedia, action: onBack)
                        .padding(.leading, ZunoMetrics.margin).padding(.top, 10)
                }
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 8).fill(ZunoColor.surface).frame(width: 260, height: 30)
                RoundedRectangle(cornerRadius: 6).fill(ZunoColor.surface).frame(height: 16)
                RoundedRectangle(cornerRadius: 6).fill(ZunoColor.surface).frame(width: 240, height: 16)
            }
            .padding(.horizontal, ZunoMetrics.margin)
            Spacer()
        }
        .padding(.top, 4)
        .accessibilityLabel(Text("Loading event"))
    }
}
