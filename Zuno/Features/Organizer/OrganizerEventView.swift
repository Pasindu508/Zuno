import SwiftUI

struct OrganizerEventView: View {
    let eventID: UUID

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppRouter.self) private var router
    @State private var draft: EventDraft?
    @State private var stats: OrganizerEventStats?
    @State private var attendees: [AttendeeRow] = []
    @State private var error: Error?
    @State private var showUpdate = false
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var message: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let draft {
                    VStack(alignment: .leading, spacing: 8) {
                        EventStatusBadge(status: draft.status)
                        Text(draft.title).zunoDisplay(.detailTitle).foregroundStyle(.zunoPrimary)
                        Text(ZunoFormat.eventDateLine(start: draft.startsAt, end: draft.endsAt)).font(.callout).foregroundStyle(.zunoSecondary)
                    }
                }
                if let stats { statsGrid(stats) }
                actions
                if let message {
                    Label(message, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.zunoPrimary)
                }
                if let stats, !stats.byTier.isEmpty {
                    FinancialsGate {
                        SurfaceCard {
                            Text("Sales by tier").font(.headline).foregroundStyle(.zunoPrimary)
                            ForEach(stats.byTier) { tier in
                                DetailLine(title: Text("\(tier.name) · \(tier.sold)/\(tier.quantity)"), value: ZunoFormat.currency(tier.gross))
                            }
                            Divider().overlay(ZunoColor.divider)
                            DetailLine(title: Text("Commission"), value: ZunoFormat.currency(-stats.commission))
                            DetailLine(title: Text("Net to you"), value: ZunoFormat.currency(stats.net), emphasized: true)
                        }
                    }
                }
                attendeeList
            }
            .padding(ZunoMetrics.margin)
            .readableWidth()
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Manage event"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showUpdate) { SendUpdateSheet(eventID: eventID) { count in message = String(AttributedString(localized: "Update sent to ^[\(count) attendee](inflect: true).").characters) } }
        .zunoContainer("organizer.eventView")
    }

    private func load() async {
        do {
            draft = try await environment.organizer.eventDraft(id: eventID)
            stats = try? await environment.organizer.stats(eventID: eventID)
            attendees = (try? await environment.organizer.attendees(eventID: eventID)) ?? []
        } catch { self.error = error }
    }

    private func statsGrid(_ stats: OrganizerEventStats) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            statTile(Text("Registered"), "\(stats.registrations)/\(stats.capacity)", symbol: "person.2")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.seal").font(.system(size: 18, weight: .light)).foregroundStyle(.zunoSecondary)
                    Spacer()
                    Gauge(value: stats.checkInProgress) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(ZunoColor.amber)
                        .scaleEffect(0.6)
                        .frame(width: 30, height: 30)
                }
                Text("\(stats.checkedIn)").font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(.zunoPrimary)
                Text("Checked in").font(.footnote).foregroundStyle(.zunoSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
            .accessibilityElement(children: .combine)
            statTile(Text("Waitlisted"), "\(stats.waitlisted)", symbol: "hourglass")
            statTile(Text("Tickets sold"), "\(stats.ticketsSold)", symbol: "ticket")
        }
    }

    private func statTile(_ title: Text, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 18, weight: .light)).foregroundStyle(.zunoSecondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(.zunoPrimary)
            title.font(.footnote).foregroundStyle(.zunoSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ZunoMetrics.cardRadius, style: .continuous).fill(ZunoColor.surface))
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if draft?.status == .published {
                Button { router.open(.checkIn(eventID)) } label: { Label("Scan tickets", systemImage: "qrcode.viewfinder") }
                    .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
                    .accessibilityIdentifier("organizer.scan")
                HStack(spacing: 10) {
                    Button { showUpdate = true } label: { Label("Send update", systemImage: "megaphone") }
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Share CSV", systemImage: "square.and.arrow.up") }
                            .buttonStyle(SecondaryCapsuleButtonStyle())
                    } else {
                        Button { Task { await export() } } label: { Label("Export", systemImage: "square.and.arrow.down") }
                            .buttonStyle(SecondaryCapsuleButtonStyle())
                            .disabled(exporting)
                            .accessibilityIdentifier("organizer.export")
                    }
                }
            } else {
                Button { router.open(.organizerEditor(eventID)) } label: { Label("Edit draft", systemImage: "pencil") }
                    .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
            }
        }
    }

    private var attendeeList: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: Text("Attendees"))
            if attendees.isEmpty {
                Text("No registrations yet.").font(.callout).foregroundStyle(.zunoSecondary)
            }
            ForEach(attendees) { attendee in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attendee.attendeeName).font(.body).foregroundStyle(.zunoPrimary)
                        Text("\(attendee.tierName) · \(attendee.registrationReference)").font(ZunoFont.mono(.caption)).foregroundStyle(.zunoTertiary)
                    }
                    Spacer()
                    if let checkedIn = attendee.checkedInAt {
                        Text(ZunoFormat.time(checkedIn)).font(.caption.weight(.semibold)).foregroundStyle(.zunoAmber)
                    } else {
                        TicketStatusBadge(status: attendee.status)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                Divider().overlay(ZunoColor.divider)
            }
        }
    }

    private func export() async {
        exporting = true
        defer { exporting = false }
        do {
            let file = try await environment.organizer.exportAttendees(eventID: eventID)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(file.filename)
            try Data(file.contents.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            exportURL = url
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct SendUpdateSheet: View {
    let eventID: UUID
    let onSent: (Int) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var kind: EventUpdateKind = .general
    @State private var text = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(EventUpdateKind.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    TextField("Message to registered attendees", text: $text, axis: .vertical).lineLimit(4...8)
                } footer: {
                    Text("Sent as an in-app notification (and push, if attendees allow it). Venue and schedule changes are highlighted.")
                }
                if let error { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
            }
            .navigationTitle(Text("Send update"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        Task {
                            sending = true
                            defer { sending = false }
                            do {
                                onSent(try await environment.organizer.sendUpdate(eventID: eventID, kind: kind, message: text))
                                dismiss()
                            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).count < 5 || sending)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
