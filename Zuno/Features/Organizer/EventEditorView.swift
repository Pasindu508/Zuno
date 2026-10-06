import PhotosUI
import SwiftUI

/// Create or edit an event draft, generate agenda/questions with the AI copilot,
/// preview, pay the creation fee and publish after server validation.
struct EventEditorView: View {
    let eventID: UUID?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var draft: EventDraft?
    @State private var organizer: OrganizerProfile?
    @State private var venues: [Venue] = []
    @State private var coverItem: PhotosPickerItem?
    @State private var coverPreview: UIImage?
    @State private var saving = false
    @State private var message: String?
    @State private var aiKind: AIDraftKind?
    @State private var showNewVenue = false
    @State private var payment = PaymentFlowModel()
    @State private var publishing = false
    @State private var feedback = 0
    @State private var tagsText = ""

    var body: some View {
        Group {
            if let binding = Binding($draft) {
                form(binding)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(eventID == nil ? Text("New event") : Text("Edit event"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await load() }
        .paymentFlow(payment)
        .onChange(of: payment.phase) { _, phase in
            if case .succeeded = phase { Task { await publish(feeJustPaid: true) } }
        }
        .sheet(item: $aiKind) { kind in
            if let draft {
                AICopilotSheet(eventID: draft.id, kind: kind) { result in apply(result) }
            }
        }
        .sheet(isPresented: $showNewVenue) {
            NewVenueSheet { venue in
                venues.append(venue)
                draft?.venueID = venue.id
            }
        }
        .sensoryFeedback(trigger: feedback) { _, _ in message == nil ? .success : .error }
        .zunoContainer("editor.view")
    }

    private func load() async {
        organizer = try? await environment.organizer.dashboard()?.organizer
        venues = (try? await environment.organizer.venues()) ?? []
        if let eventID, let existing = try? await environment.organizer.eventDraft(id: eventID) {
            draft = existing
        } else if let organizer {
            draft = EventDraft(organizerID: organizer.id, now: environment.now)
        }
        tagsText = draft?.tags.joined(separator: ", ") ?? ""
    }

    private func form(_ draft: Binding<EventDraft>) -> some View {
        let issues = draft.wrappedValue.validationIssues(now: environment.now)
        return Form {
            Section("Basics") {
                TextField("Title", text: draft.title).accessibilityIdentifier("editor.title")
                TextField("One-line summary", text: draft.summary).accessibilityIdentifier("editor.summary")
                TextField("Description", text: draft.description, axis: .vertical).lineLimit(4...10)
                    .accessibilityIdentifier("editor.description")
                Picker("Category", selection: draft.categoryID) {
                    ForEach(EventCategory.defaults) { Label($0.name, systemImage: $0.symbolName).tag($0.id) }
                }
                TextField("University (optional)", text: draft.university)
                TextField("Tags, separated by commas", text: $tagsText)
                    .onChange(of: tagsText) { _, value in
                        draft.wrappedValue.tags = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
            }
            .listRowBackground(ZunoColor.surface)

            Section("Schedule") {
                DatePicker("Starts", selection: draft.startsAt, in: environment.now...)
                DatePicker("Ends", selection: draft.endsAt, in: draft.wrappedValue.startsAt...)
                Toggle("Close registration early", isOn: Binding(
                    get: { draft.wrappedValue.registrationClosesAt != nil },
                    set: { draft.wrappedValue.registrationClosesAt = $0 ? draft.wrappedValue.startsAt.addingTimeInterval(-3600) : nil }
                ))
                if let closes = draft.wrappedValue.registrationClosesAt {
                    DatePicker("Registration closes", selection: Binding(get: { closes }, set: { draft.wrappedValue.registrationClosesAt = $0 }),
                               in: environment.now...draft.wrappedValue.startsAt)
                }
            }
            .listRowBackground(ZunoColor.surface)

            Section("Venue") {
                Picker("Format", selection: draft.format) {
                    Text("In person").tag(EventFormat.physical)
                    Text("Online").tag(EventFormat.online)
                    Text("Hybrid").tag(EventFormat.hybrid)
                }
                .pickerStyle(.segmented)
                if draft.wrappedValue.format != .online {
                    Picker("Venue", selection: draft.venueID) {
                        Text("Choose a venue").tag(UUID?.none)
                        ForEach(venues) { Text("\($0.name), \($0.city)").tag(Optional($0.id)) }
                    }
                    Button("Add a new venue") { showNewVenue = true }
                }
                if draft.wrappedValue.format != .physical {
                    TextField("Online link (https://…)", text: draft.onlineURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                }
            }
            .listRowBackground(ZunoColor.surface)

            Section {
                Toggle("Free event", isOn: draft.isFree)
                Stepper("Capacity: \(draft.wrappedValue.capacity)", value: draft.capacity, in: 1...20_000, step: 10)
                if !draft.wrappedValue.isFree {
                    ForEach(draft.tiers) { $tier in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Tier name", text: $tier.name)
                            HStack {
                                Text("Price (LKR)")
                                TextField("1500", value: Binding(get: { tier.price.minorUnits / 100 }, set: { tier.price = .rupees(max($0, 0)) }), format: .number)
                                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            }
                            Stepper("Quantity: \(tier.quantity)", value: $tier.quantity, in: 1...20_000, step: 10)
                            Stepper("Max per order: \(tier.maxPerOrder)", value: $tier.maxPerOrder, in: 1...20)
                        }
                    }
                    .onDelete { draft.wrappedValue.tiers.remove(atOffsets: $0) }
                    Button("Add ticket tier") { draft.wrappedValue.tiers.append(TierDraft(name: String(localized: "General"))) }
                }
            } header: {
                Text("Tickets")
            } footer: {
                Text(draft.wrappedValue.isFree
                     ? "Attendees use their monthly free allowance; Zuno handles any wallet fee."
                     : "Prices are charged by PayHere. Zuno's 5% commission is deducted from your settlement.")
            }
            .listRowBackground(ZunoColor.surface)

            Section {
                ForEach(draft.questions) { $question in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Question", text: $question.prompt)
                        Picker("Answer type", selection: $question.kind) {
                            Text("Short text").tag(QuestionKind.shortText)
                            Text("Long text").tag(QuestionKind.longText)
                            Text("Single choice").tag(QuestionKind.singleChoice)
                            Text("Multiple choice").tag(QuestionKind.multiChoice)
                            Text("Yes / No").tag(QuestionKind.yesNo)
                        }
                        if question.kind == .singleChoice || question.kind == .multiChoice {
                            TextField("Options, separated by commas", text: Binding(
                                get: { question.options.joined(separator: ", ") },
                                set: { question.options = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                            ))
                        }
                        Toggle("Required", isOn: $question.required)
                    }
                }
                .onDelete { draft.wrappedValue.questions.remove(atOffsets: $0) }
                Button("Add question") { draft.wrappedValue.questions.append(QuestionDraft()) }
                Button { Task { await openAI(.questions) } } label: { Label("Suggest questions with AI", systemImage: "wand.and.sparkles") }
                    .accessibilityIdentifier("editor.aiQuestions")
            } header: {
                Text("Registration questions")
            }
            .listRowBackground(ZunoColor.surface)

            Section {
                ForEach(draft.agenda) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Session title", text: $item.title)
                        DatePicker("Starts", selection: $item.startsAt)
                        DatePicker("Ends", selection: $item.endsAt, in: item.startsAt...)
                        TextField("Details", text: $item.detail, axis: .vertical)
                    }
                }
                .onDelete { draft.wrappedValue.agenda.remove(atOffsets: $0) }
                Button("Add session") {
                    let start = draft.wrappedValue.agenda.last?.endsAt ?? draft.wrappedValue.startsAt
                    draft.wrappedValue.agenda.append(AgendaItem(startsAt: start, endsAt: start.addingTimeInterval(3600), title: "", detail: ""))
                }
                Button { Task { await openAI(.agenda) } } label: { Label("Draft an agenda with AI", systemImage: "wand.and.sparkles") }
                    .accessibilityIdentifier("editor.aiAgenda")
            } header: {
                Text("Agenda")
            } footer: {
                Text("AI suggestions are drafts. Review and edit them before publishing — nothing is added without your approval.")
            }
            .listRowBackground(ZunoColor.surface)

            Section("Cover image") {
                PhotosPicker(selection: $coverItem, matching: .images) {
                    Label(draft.wrappedValue.coverPath == nil ? "Choose cover image" : "Replace cover image", systemImage: "photo")
                }
                if let coverPreview {
                    Image(uiImage: coverPreview).resizable().scaledToFill().frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 14))
                }
                TextField("Describe the image for VoiceOver", text: draft.coverAlt)
            }
            .listRowBackground(ZunoColor.surface)
            .onChange(of: coverItem) { _, item in Task { await uploadCover(item) } }

            Section("Refunds and cancellation") {
                TextField("Policy shown to attendees", text: draft.refundPolicy, axis: .vertical).lineLimit(2...5)
            }
            .listRowBackground(ZunoColor.surface)

            Section("Preview") {
                EventCard(event: preview(draft.wrappedValue), now: environment.now)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                    .allowsHitTesting(false)
            }
            .listRowBackground(Color.clear)

            if !issues.isEmpty {
                Section("Before you can publish") {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.zunoAmber)
                    }
                }
                .listRowBackground(ZunoColor.surface)
            }

            if let message {
                Section { Text(message).font(.footnote) }.listRowBackground(ZunoColor.surface)
            }

            Section {
                Button("Save draft") { Task { await save() } }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .disabled(saving)
                    .accessibilityIdentifier("editor.save")
                Button(draft.wrappedValue.creationFeePaid ? "Publish event" : "Pay LKR 1,000 fee and publish") {
                    Task { await publish(feeJustPaid: false) }
                }
                .buttonStyle(PrimaryCapsuleButtonStyle(compact: true, isLoading: publishing || payment.isBusy))
                .disabled(!issues.isEmpty || organizer?.verification != .verified || publishing)
                .accessibilityIdentifier("editor.publish")
                if organizer?.verification != .verified {
                    Text("Publishing unlocks after organizer verification.").font(.footnote).foregroundStyle(.zunoSecondary)
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
        .scrollContentBackground(.hidden)
        .tint(ZunoColor.amber)
    }

    private func preview(_ draft: EventDraft) -> EventSummary {
        let venue = venues.first { $0.id == draft.venueID }
        let cover: ImageReference? = draft.coverPath.map {
            $0.hasPrefix("seed-") ? .bundled(name: $0) : .storage(bucket: StorageBucket.eventMedia, path: $0)
        }
        return EventSummary(
            id: draft.id, title: draft.title.isEmpty ? String(localized: "Event title") : draft.title,
            summary: draft.summary, categoryID: draft.categoryID,
            categoryName: EventCategory.defaults.first { $0.id == draft.categoryID }?.name ?? "",
            organizerID: draft.organizerID, organizerName: organizer?.name ?? "", venueName: venue?.name, city: venue?.city,
            district: venue?.district, location: venue?.location, university: draft.university.isEmpty ? nil : draft.university,
            format: draft.format, startsAt: draft.startsAt, endsAt: draft.endsAt, isFree: draft.isFree,
            minPrice: draft.tiers.map(\.price).min(), capacity: draft.capacity, seatsRemaining: draft.capacity,
            cover: cover, coverAlt: draft.coverAlt, tags: draft.tags, status: .draft
        )
    }

    @discardableResult
    private func save() async -> Bool {
        guard let current = draft else { return false }
        saving = true
        defer { saving = false }
        do {
            draft = try await environment.organizer.saveEventDraft(current)
            message = String(localized: "Draft saved.")
            return true
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedback += 1
            return false
        }
    }

    private func uploadCover(_ item: PhotosPickerItem?) async {
        guard let item, let current = draft, let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.82) else { return }
        coverPreview = image
        do {
            if eventID == nil { _ = await save() }
            draft?.coverPath = try await environment.organizer.uploadEventImage(eventID: current.id, organizerID: current.organizerID, jpegData: jpeg)
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The copilot works on the saved draft, so save first.
    private func openAI(_ kind: AIDraftKind) async {
        if await save() { aiKind = kind }
    }

    private func apply(_ result: AIDraftResult) {
        switch result.kind {
        case .agenda: draft?.agenda = result.agenda
        case .questions: draft?.questions.append(contentsOf: result.questions)
        }
        message = String(localized: "AI suggestions added. Review them before publishing.")
    }

    private func publish(feeJustPaid: Bool) async {
        guard let current = draft else { return }
        guard await save() else { return }
        if !current.creationFeePaid && !feeJustPaid {
            guard let phone = session.profile?.phone.flatMap(SriLankaLocations.normalizedMobile) else {
                message = String(localized: "Add your mobile number in Edit profile first — PayHere sends the fee receipt there.")
                feedback += 1
                return
            }
            await payment.start(purpose: .eventCreationFee(eventID: current.id), phone: phone, environment: environment)
            return
        }
        publishing = true
        defer { publishing = false }
        do {
            try await environment.organizer.submitForPublish(eventID: current.id)
            message = nil
            feedback += 1
            router.open(.organizerEvent(current.id))
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            feedback += 1
        }
    }
}

extension AIDraftKind: Identifiable {
    var id: String { rawValue }
}

struct NewVenueSheet: View {
    let onCreate: (Venue) -> Void
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var city = "Colombo"
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("Venue name", text: $name)
                TextField("Address", text: $address)
                Picker("City", selection: $city) {
                    ForEach(SriLankaLocations.places) { Text($0.city).tag($0.city) }
                }
                if let error { Text(error).foregroundStyle(Color(uiColor: .systemRed)) }
            }
            .navigationTitle(Text("New venue"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            do {
                                onCreate(try await environment.organizer.createVenue(name: name, addressLine: address, city: city))
                                dismiss()
                            } catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
                        }
                    }
                    .disabled(name.count < 3)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// AI organizer copilot: structured agenda / question drafts with explicit approval,
/// retry, cancellation and clear handling of timeout, refusal and malformed output.
struct AICopilotSheet: View {
    let eventID: UUID
    let kind: AIDraftKind
    let onApprove: (AIDraftResult) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var instructions = ""
    @State private var phase: Phase = .idle
    @State private var task: Task<Void, Never>?

    enum Phase {
        case idle
        case generating
        case result(AIDraftResult)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == .agenda ? "Anything to include? (optional)" : "What do you need to know from attendees? (optional)",
                              text: $instructions, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("Zuno's copilot drafts suggestions only. It never publishes, prices tickets or handles payments.")
                }
                switch phase {
                case .idle:
                    EmptyView()
                case .generating:
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Drafting \(kind == .agenda ? "an agenda" : "questions")…")
                        }
                        Button("Cancel", role: .cancel) {
                            task?.cancel()
                            phase = .idle
                        }
                    }
                case .result(let result):
                    Section("Suggestion") {
                        if result.kind == .agenda {
                            ForEach(result.agenda) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(ZunoFormat.time(item.startsAt)) – \(ZunoFormat.time(item.endsAt))").font(ZunoFont.mono(.caption))
                                    Text(item.title).font(.body.weight(.semibold))
                                    if !item.detail.isEmpty { Text(item.detail).font(.footnote).foregroundStyle(.zunoSecondary) }
                                }
                            }
                        } else {
                            ForEach(result.questions) { question in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(question.prompt).font(.body.weight(.semibold))
                                    Text(question.kind.rawValue.replacingOccurrences(of: "_", with: " ") + (question.required ? " · required" : ""))
                                        .font(.footnote).foregroundStyle(.zunoSecondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button("Use these suggestions") {
                            onApprove(result)
                            Task { try? await environment.organizer.resolveDraft(id: result.draftID, approved: true) }
                            dismiss()
                        }
                        .accessibilityIdentifier("ai.approve")
                        Button("Try again") { generate() }
                        Button("Discard", role: .destructive) {
                            Task { try? await environment.organizer.resolveDraft(id: result.draftID, approved: false) }
                            dismiss()
                        }
                    }
                case .failed(let message):
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.zunoAmber)
                        Button("Retry") { generate() }
                    }
                }
            }
            .navigationTitle(kind == .agenda ? Text("AI agenda") : Text("AI questions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { task?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Generate") { generate() }
                        .disabled({ if case .generating = phase { return true }; return false }())
                        .accessibilityIdentifier("ai.generate")
                }
            }
        }
        .presentationDetents([.large])
        .onDisappear { task?.cancel() }
    }

    private func generate() {
        task?.cancel()
        phase = .generating
        let instructions = instructions.isEmpty ? nil : instructions
        task = Task {
            do {
                let result = try await environment.organizer.generateDraft(eventID: eventID, kind: kind, instructions: instructions)
                guard !Task.isCancelled else { return }
                phase = .result(result)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(Self.message(for: error))
            }
        }
    }

    static func message(for error: Error) -> String {
        if case .server(let code, _)? = error as? ZunoError {
            switch code {
            case "ai_timeout": return String(localized: "The copilot took too long. Try again.")
            case "ai_refused": return String(localized: "The copilot couldn't help with that request. Try rewording your instructions.")
            case "ai_malformed": return String(localized: "The copilot returned something we couldn't use. Try again.")
            case "ai_unavailable": return String(localized: "The copilot isn't available right now.")
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
