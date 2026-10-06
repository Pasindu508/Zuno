import Observation
import SwiftUI

@MainActor
@Observable
final class TicketsModel {
    var tickets: [Ticket] = []
    var state: Loadable<Void> = .idle
    var isShowingCached = false

    /// Shows cached tickets immediately (offline-safe), then refreshes from the server.
    func load(environment: AppEnvironment, userID: UUID?) async {
        guard let userID else { return }
        if tickets.isEmpty {
            let cached = await environment.ticketCache.load(for: userID)
            if !cached.isEmpty {
                tickets = cached
                isShowingCached = true
                state = .loaded(())
            } else {
                state = .loading
            }
        }
        do {
            let fresh = try await environment.tickets.tickets()
            tickets = fresh
            isShowingCached = false
            state = .loaded(())
            await environment.ticketCache.save(fresh, for: userID)
        } catch {
            if tickets.isEmpty { state = .failed(error) }
        }
    }

    func ticket(matching id: UUID) -> Ticket? {
        tickets.first { $0.id == id } ?? tickets.filter { $0.event.id == id && $0.status != .cancelled }.first
    }
}

struct TicketsTabRoot: View {
    @Environment(AppRouter.self) private var router
    @State private var model = TicketsModel()

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.ticketsPath) {
            TicketsView()
                .navigationDestination(for: AppRoute.self) { AppDestination(route: $0, namespace: nil) }
        }
        .environment(model)
    }
}

struct TicketsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(NetworkMonitor.self) private var network
    @Environment(TicketsModel.self) private var model
    @State private var segment: TicketSegment = .upcoming

    var body: some View {
        Group {
            if !session.isSignedIn {
                SignInPromptView(title: Text("Your tickets live here"),
                                 message: Text("Sign in to register for events and keep your QR tickets available offline."))
            } else {
                content
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Tickets"))
        .task(id: session.user?.id) { await model.load(environment: environment, userID: session.user?.id) }
        .refreshable { await model.load(environment: environment, userID: session.user?.id) }
    }

    @ViewBuilder
    private var content: some View {
        let groups = TicketSegment.group(model.tickets, now: environment.now)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(selection: $segment) {
                    ForEach(TicketSegment.allCases) { Text($0.title).tag($0) }
                } label: { Text("Ticket list") }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: segment)
                .accessibilityIdentifier("tickets.segment")

                if !network.isOnline || model.isShowingCached { OfflineBanner() }

                switch model.state {
                case .idle, .loading:
                    ForEach(0..<2, id: \.self) { _ in ShimmerPlaceholder().frame(height: 128).clipShape(RoundedRectangle(cornerRadius: 18)) }
                case .failed(let error):
                    ErrorStateView(error: error) { Task { await model.load(environment: environment, userID: session.user?.id) } }
                        .frame(minHeight: 320)
                case .loaded:
                    let items = groups[segment] ?? []
                    if items.isEmpty {
                        EmptyStateView(symbol: "ticket", title: emptyTitle, message: emptyMessage)
                            .frame(minHeight: 320)
                    } else {
                        ForEach(items) { ticket in
                            NavigationLink(value: AppRoute.ticket(ticket.id)) { TicketCard(ticket: ticket) }
                                .buttonStyle(CardPressStyle())
                                .accessibilityIdentifier("tickets.row")
                        }
                    }
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .readableWidth()
        }
    }

    private var emptyTitle: Text {
        switch segment {
        case .upcoming: Text("No upcoming tickets")
        case .past: Text("No past events yet")
        case .cancelled: Text("No cancelled tickets")
        }
    }

    private var emptyMessage: Text {
        switch segment {
        case .upcoming: Text("Register for an event and your QR ticket will appear here.")
        case .past: Text("Events you've attended will be kept here.")
        case .cancelled: Text("Cancelled and refunded tickets appear here.")
        }
    }
}

/// Dark ticket with a white QR surface; full-screen QR for scanning at the door.
struct TicketDetailView: View {
    let ticketID: UUID
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @State private var model = TicketsModel()
    @State private var fullScreen = false

    var body: some View {
        BiometricGatedView(purpose: .ticketDetails) {
            Group {
                if let ticket = model.ticket(matching: ticketID) {
                    content(ticket)
                } else if case .failed(let error) = model.state {
                    ErrorStateView(error: error) { Task { await model.load(environment: environment, userID: session.user?.id) } }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Ticket"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await model.load(environment: environment, userID: session.user?.id) }
        .zunoContainer("ticket.detail")
    }

    private func content(_ ticket: Ticket) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ArtworkImage(reference: ticket.event.cover, accessibilityLabel: ticket.event.coverAlt)
                    .frame(height: 170)
                    .overlay(alignment: .bottomLeading) {
                        DatePill(text: Text(ZunoFormat.weekdayDayMonth(ticket.event.startsAt)))
                            .padding(14)
                    }
                VStack(alignment: .leading, spacing: 16) {
                    Text(ticket.event.title)
                        .zunoDisplay(.cardTitle)
                        .foregroundStyle(.zunoPrimary)
                    HStack {
                        TicketStatusBadge(status: ticket.status)
                        Spacer()
                        Text(ticket.tierName).font(.subheadline.weight(.medium)).foregroundStyle(.zunoSecondary)
                    }
                    Button {
                        fullScreen = true
                    } label: {
                        QRSurface(payload: ticket.qrPayload, size: 210)
                            .opacity(ticket.status == .valid ? 1 : 0.35)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .disabled(ticket.status != .valid)
                    .accessibilityHint(Text("Shows the QR code full screen"))
                    Text(ticket.code)
                        .font(ZunoFont.mono(.title3, weight: .semibold))
                        .foregroundStyle(.zunoPrimary)
                        .frame(maxWidth: .infinity)
                        .textSelection(.enabled)
                        .accessibilityLabel(Text("Manual code \(ticket.code.map { String($0) }.joined(separator: " "))"))
                    TicketPerforation()
                    VStack(spacing: 12) {
                        DetailLine(title: Text("Attendee"), value: ticket.attendeeName)
                        DetailLine(title: Text("Date"), value: ZunoFormat.longDay(ticket.event.startsAt))
                        DetailLine(title: Text("Time"), value: ZunoFormat.timeRange(start: ticket.event.startsAt, end: ticket.event.endsAt))
                        DetailLine(title: Text("Venue"), value: [ticket.event.venueName, ticket.event.city].compactMap { $0 }.joined(separator: ", "))
                        DetailLine(title: Text("Reference"), value: ticket.registrationReference)
                            .font(ZunoFont.mono(.subheadline))
                        if let checkedIn = ticket.checkedInAt {
                            DetailLine(title: Text("Checked in"), value: ZunoFormat.compactTimestamp(checkedIn))
                        }
                    }
                    Text("This ticket is saved on your device and works without a connection.")
                        .font(.caption).foregroundStyle(.zunoTertiary)
                }
                .padding(20)
            }
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(ZunoColor.surface))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.vertical, 12)
            .readableWidth(520)
        }
        .fullScreenCover(isPresented: $fullScreen) {
            FullScreenQRView(ticket: ticket)
        }
    }
}

struct TicketPerforation: View {
    var body: some View {
        Line()
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 6]))
            .foregroundStyle(ZunoColor.divider)
            .frame(height: 1)
            .padding(.vertical, 4)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: 0, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            }
        }
    }
}

/// Bright white full-screen QR; raises screen brightness while visible.
struct FullScreenQRView: View {
    let ticket: Ticket
    @Environment(\.dismiss) private var dismiss
    @State private var previousBrightness: CGFloat?

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 22) {
                Text(ticket.event.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                QRSurface(payload: ticket.qrPayload, size: 290)
                Text(ticket.code).font(ZunoFont.mono(.title2, weight: .semibold)).foregroundStyle(.black)
                Text(ticket.attendeeName).font(.body).foregroundStyle(.black.opacity(0.7))
                Button("Done") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.top, 8)
                    .accessibilityIdentifier("qr.done")
            }
            .padding(24)
        }
        .onAppear {
            guard let screen = UIApplication.shared.zunoKeyWindow?.windowScene?.screen else { return }
            previousBrightness = screen.brightness
            screen.brightness = 1
        }
        .onDisappear {
            if let previousBrightness, let screen = UIApplication.shared.zunoKeyWindow?.windowScene?.screen {
                screen.brightness = previousBrightness
            }
        }
        .preferredColorScheme(.light)
    }
}

/// Shared prompt for guests on account-only tabs.
struct SignInPromptView: View {
    let title: Text
    let message: Text
    @Environment(SessionStore.self) private var session

    var body: some View {
        StateMessageView(symbol: "person.crop.circle", title: title, message: message,
                         action: (Text("Sign in"), { session.requireAccount(for: .openTab(.home)) }))
            .zunoContainer("signin.prompt")
    }
}
