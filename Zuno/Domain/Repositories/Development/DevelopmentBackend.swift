#if DEBUG
import Foundation

/// In-memory stand-in for the Supabase backend, compiled into Debug builds only.
///
/// It exists so the app can be reviewed in the simulator and exercised by UI tests
/// without credentials. It applies the same business rules as the SQL functions
/// (allowance, wallet deduction, capacity, idempotency, inventory, check-in) using the
/// shared Swift policies, but it is NOT the authority in production — the database is.
actor DevelopmentBackend {
    // MARK: State

    struct DevEvent {
        var summary: EventSummary
        var description: String
        var addressLine: String?
        var onlineURL: URL?
        var agenda: [AgendaItem]
        var speakers: [Speaker]
        var refundPolicy: String
        var tiers: [TicketTier]
        var questions: [RegistrationQuestion]
        var seatsTaken: Int
        var creationFeePaid = true
    }

    struct DevRegistration {
        var id: UUID
        var eventID: UUID
        var userID: UUID
        var status: RegistrationStatus
        var kind: RegistrationKind
        var fee: Money
        var reference: String
        var createdAt: Date
    }

    struct DevTicket {
        var ticket: Ticket
        var userID: UUID
    }

    struct DevOrder {
        var snapshot: OrderSnapshot
        var userID: UUID
        var items: [CheckoutItem]
        var answers: [RegistrationAnswer]
        var summary: OrderSummary
        var expiresAt: Date
    }

    private let clock: @Sendable () -> Date
    private var policy = FreeRegistrationPolicy()
    private let commissionBps = CommissionPolicy.defaultBasisPoints

    private var categories: [EventCategory] = EventCategory.defaults
    private var organizers: [UUID: OrganizerProfile] = [:]
    private var organizerOwners: [UUID: UUID] = [:]
    private var venues: [UUID: Venue] = [:]
    private var events: [UUID: DevEvent] = [:]
    private var registrations: [DevRegistration] = []
    private var tickets: [DevTicket] = []
    private var orders: [UUID: DevOrder] = [:]
    private var processedGatewayEvents: Set<String> = []
    private var registrationReplays: [String: RegistrationConfirmation] = [:]
    private var checkoutReplays: [String: CheckoutSession] = [:]

    private var profiles: [UUID: UserProfile] = [:]
    private var balances: [UUID: Int64] = [:]
    private var ledgers: [UUID: [WalletTransaction]] = [:]
    private var allowanceUsed: [UUID: [String: Int]] = [:]
    private var saved: [UUID: Set<UUID>] = [:]
    private var followed: [UUID: Set<UUID>] = [:]
    private var notificationsByUser: [UUID: [AppNotification]] = [:]
    private var preferencesByUser: [UUID: NotificationPreferences] = [:]
    private var identityDigests: [String: UUID] = [:]
    private var notificationContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    private(set) var currentUserID: UUID?
    let developmentUserID: UUID
    var simulatedLatency: Duration = .milliseconds(350)

    // MARK: Init

    /// `async` so the initializer is isolated to the actor and can seed state directly.
    init(now: @escaping @Sendable () -> Date = { .now }, makeDevelopmentUserOrganizer: Bool = false) async {
        clock = now
        let seed = try? SeedDocument.load()
        developmentUserID = seed?.developmentUser.id ?? UUID(uuidString: "b0000000-0000-4000-8000-0000000000aa")!
        if let seed { applySeed(seed, organizerMode: makeDevelopmentUserOrganizer) }
        // Simulated digest of a NIC "already registered" elsewhere: 851234567V / 198512304567.
        identityDigests["198512304567"] = UUID()
    }

    private func applySeed(_ seed: SeedDocument, organizerMode: Bool) {
        let now = clock()
        self.categories = seed.categories.map(\.domain).sorted { $0.sortOrder < $1.sortOrder }
        for organizer in seed.organizers {
            self.organizers[organizer.id] = OrganizerProfile(
                id: organizer.id, name: organizer.name, slug: organizer.slug, bio: organizer.bio, logoPath: nil,
                contactEmail: organizer.contactEmail, verification: organizer.verificationStatus
            )
            self.organizerOwners[organizer.id] = organizer.ownerId
        }
        let devUser = seed.developmentUser
        if organizerMode, let builders = seed.organizers.first {
            self.organizerOwners[builders.id] = devUser.id
        }
        for venue in seed.venues {
            self.venues[venue.id] = Venue(id: venue.id, name: venue.name, addressLine: venue.addressLine, city: venue.city,
                                             district: venue.district, location: GeoPoint(latitude: venue.latitude, longitude: venue.longitude))
        }
        let categoryNames = Dictionary(uniqueKeysWithValues: self.categories.map { ($0.id, $0.name) })
        for item in seed.events {
            let start = SeedDocument.startDate(offsetDays: item.startOffsetDays, time: item.startTime, now: now)
            let end = start.addingTimeInterval(item.durationHours * 3600)
            let venue = item.venueId.flatMap { self.venues[$0] }
            let tiers = item.tiers.map { tier in
                TicketTier(id: tier.id, name: tier.name, description: tier.description, price: .lkr(tier.priceMinor),
                           quantity: tier.quantity, remaining: tier.quantity - tier.sold, maxPerOrder: tier.maxPerOrder,
                           salesStartAt: nil, salesEndAt: start, onSale: true)
            }
            let capacity = item.isFree ? item.capacity : max(item.capacity, tiers.reduce(0) { $0 + $1.quantity })
            let seatsTaken = item.isFree ? item.seatsTaken : tiers.reduce(0) { $0 + ($1.quantity - $1.remaining) }
            let summary = EventSummary(
                id: item.id, title: item.title, summary: item.summary, categoryID: item.categoryId,
                categoryName: categoryNames[item.categoryId] ?? item.categoryId.capitalized,
                organizerID: item.organizerId, organizerName: self.organizers[item.organizerId]?.name ?? "",
                venueName: venue?.name, city: venue?.city, district: venue?.district, location: venue?.location,
                university: item.university, format: item.format, startsAt: start, endsAt: end, isFree: item.isFree,
                minPrice: tiers.map(\.price).min(), capacity: capacity, seatsRemaining: max(capacity - seatsTaken, 0),
                cover: .bundled(name: "seed-\(item.slug)"), coverAlt: item.coverAlt, tags: item.tags, status: .published
            )
            self.events[item.id] = DevEvent(
                summary: summary, description: item.description, addressLine: venue?.addressLine,
                onlineURL: item.format == .physical ? nil : URL(string: "https://meet.zuno.example/\(item.slug)"),
                agenda: item.agenda.map {
                    let s = start.addingTimeInterval($0.offsetHours * 3600)
                    return AgendaItem(startsAt: s, endsAt: s.addingTimeInterval($0.durationHours * 3600), title: $0.title, detail: $0.detail)
                },
                speakers: item.speakers.map { Speaker(name: $0.name, role: $0.role, organization: $0.organization) },
                refundPolicy: item.refundPolicy,
                tiers: tiers,
                questions: item.questions.enumerated().map { index, question in
                    RegistrationQuestion(id: Self.stableUUID(item.id, index), prompt: question.prompt, kind: question.kind,
                                         options: question.options, required: question.required)
                },
                seatsTaken: seatsTaken
            )
        }
        self.seedDevelopmentUser(devUser, seed: seed, now: now)
        if organizerMode, let builders = seed.organizers.first { self.seedOrganizerAttendees(organizerID: builders.id, now: now) }
    }

    private func seedDevelopmentUser(_ user: SeedDocument.DevelopmentUser, seed: SeedDocument, now: Date) {
        profiles[user.id] = UserProfile(
            id: user.id, displayName: user.displayName, avatarPath: nil, city: user.city, district: user.district,
            preferredCategories: user.preferredCategories, language: .en, accessibilityNeeds: [], phone: "+94771234567",
            identityStatus: .verifiedUnique, onboardingCompletedAt: now.addingTimeInterval(-86_400 * 60)
        )
        allowanceUsed[user.id] = [FreeRegistrationPolicy.monthKey(for: now): user.allowanceUsedThisMonth]
        let day: TimeInterval = 86_400
        let history: [(WalletEntryType, Int64, LedgerStatus, String, TimeInterval)] = [
            (.topup, 10_000, .posted, "PayHere top-up", -day * 41),
            (.freeRegistrationFee, -250, .posted, "Free registration beyond monthly allowance", -day * 36),
            (.freeRegistrationFee, -250, .posted, "Free registration beyond monthly allowance", -day * 35),
            (.topup, 200_000, .failed, "PayHere top-up declined", -day * 12),
            (.topup, 5_000, .posted, "PayHere top-up", -day * 11),
            (.freeRegistrationFee, -250, .posted, "Free registration beyond monthly allowance", -day * 33),
            (.refundCredit, -250, .posted, "Correction", -day * 33),
        ]
        // Build a ledger whose posted entries sum exactly to the seeded balance.
        var entries: [WalletTransaction] = []
        var running: Int64 = 0
        for (type, amount, status, text, offset) in history.prefix(5) {
            if status == .posted { running += amount }
            entries.append(WalletTransaction(id: UUID(), type: type, amount: .lkr(amount), balanceAfter: status == .posted ? .lkr(running) : nil,
                                             status: status, description: text, referenceType: nil, referenceID: nil, createdAt: now.addingTimeInterval(offset)))
        }
        let correction = user.walletBalanceMinor - running
        if correction != 0 {
            running += correction
            entries.append(WalletTransaction(id: UUID(), type: correction > 0 ? .refundCredit : .freeRegistrationFee, amount: .lkr(correction),
                                             balanceAfter: .lkr(running), status: .posted,
                                             description: correction > 0 ? "Refund credit — cancelled event" : "Free registration beyond monthly allowance",
                                             referenceType: nil, referenceID: nil, createdAt: now.addingTimeInterval(-day * 6)))
        }
        balances[user.id] = running
        ledgers[user.id] = entries.sorted { $0.createdAt > $1.createdAt }
        preferencesByUser[user.id] = NotificationPreferences()

        let bySlug = Dictionary(uniqueKeysWithValues: seed.events.map { ($0.slug, $0.id) })
        for slug in user.registeredEventSlugs {
            guard let eventID = bySlug[slug], let event = events[eventID] else { continue }
            let registration = DevRegistration(id: UUID(), eventID: eventID, userID: user.id, status: .confirmed, kind: .free, fee: .zero,
                                               reference: Self.reference(prefix: "ZR"), createdAt: event.summary.startsAt.addingTimeInterval(-day * 8))
            registrations.append(registration)
            issueTicket(for: registration, tierName: String(localized: "Free admission"), orderID: nil, holder: user.displayName)
        }
        for slug in user.paidTicketEventSlugs {
            guard let eventID = bySlug[slug], let event = events[eventID], let tier = event.tiers.first else { continue }
            let order = UUID()
            let registration = DevRegistration(id: UUID(), eventID: eventID, userID: user.id, status: .confirmed, kind: .paid, fee: .zero,
                                               reference: Self.reference(prefix: "ZR"), createdAt: now.addingTimeInterval(-day * 3))
            registrations.append(registration)
            issueTicket(for: registration, tierName: tier.name, orderID: order, holder: user.displayName)
            issueTicket(for: registration, tierName: tier.name, orderID: order, holder: user.displayName)
        }
        saved[user.id] = Set(user.savedEventSlugs.compactMap { bySlug[$0] })
        followed[user.id] = [seed.organizers[1].id]

        let jazz = bySlug["jazz-under-the-stars"], oss = bySlug["open-source-day"], galle = bySlug["galle-photo-walk"]
        notificationsByUser[user.id] = [
            AppNotification(id: UUID(), kind: .eventReminder, title: "Open Source Community Day is in 4 days",
                            body: "Bring your laptop. Doors open at 9:30 AM at Innovation Hall.", eventID: oss, readAt: nil,
                            createdAt: now.addingTimeInterval(-3_600 * 2)),
            AppNotification(id: UUID(), kind: .ticketIssued, title: "Your tickets for Jazz Under the Stars",
                            body: "2 × Lawn tickets are in the Tickets tab.", eventID: jazz, readAt: nil,
                            createdAt: now.addingTimeInterval(-day * 3)),
            AppNotification(id: UUID(), kind: .waitlistMovement, title: "Seats are filling up",
                            body: "Golden Hour in Galle Fort has 3 places left.", eventID: galle, readAt: now.addingTimeInterval(-day),
                            createdAt: now.addingTimeInterval(-day * 2)),
            AppNotification(id: UUID(), kind: .paymentStatus, title: "Top-up received",
                            body: "LKR 50.00 was added to your wallet.", eventID: nil, readAt: now.addingTimeInterval(-day * 10),
                            createdAt: now.addingTimeInterval(-day * 11)),
        ]
    }

    /// Fictional attendees so organizer dashboards, exports and check-in have data.
    private func seedOrganizerAttendees(organizerID: UUID, now: Date) {
        let names = ["Ishan Wijesinghe", "Dilshani Rathnayake", "Arjun Navaratnam", "Fathima Rizwan", "Kasun Bandara",
                     "Shalini Murugesu", "Ruwan Senanayake", "Amaya Gunasekara", "Tharindu Silva", "Priya Thevarajah"]
        for event in events.values where event.summary.organizerID == organizerID && !event.summary.hasEnded(now: now) {
            for (index, name) in names.enumerated() {
                let userID = UUID()
                let registration = DevRegistration(id: UUID(), eventID: event.summary.id, userID: userID, status: .confirmed,
                                                   kind: event.summary.isFree ? .free : .paid, fee: .zero,
                                                   reference: Self.reference(prefix: "ZR"), createdAt: now.addingTimeInterval(-Double(index) * 3_600))
                registrations.append(registration)
                let ticket = issueTicket(for: registration, tierName: event.tiers.first?.name ?? String(localized: "Free admission"),
                                         orderID: event.summary.isFree ? nil : UUID(), holder: name)
                if index < 3 { checkInDirect(ticketID: ticket.id, at: now.addingTimeInterval(-Double(index + 1) * 600)) }
            }
        }
        // A deterministic ticket for UI tests: code ZN-TEST-0001 on the first free organizer event.
        if let event = events.values.filter({ $0.summary.organizerID == organizerID && $0.summary.isFree }).min(by: { $0.summary.startsAt < $1.summary.startsAt }) {
            let registration = DevRegistration(id: UUID(), eventID: event.summary.id, userID: UUID(), status: .confirmed, kind: .free,
                                               fee: .zero, reference: "ZR-TEST0001", createdAt: now)
            registrations.append(registration)
            var ticket = issueTicket(for: registration, tierName: String(localized: "Free admission"), orderID: nil, holder: "Test Attendee")
            ticket.code = "ZN-TEST-0001"
            ticket.qrPayload = "zuno:t:test-token-0001"
            if let index = tickets.firstIndex(where: { $0.ticket.id == ticket.id }) {
                tickets[index].ticket = ticket
            }
        }
    }

    // MARK: Session

    func signIn(userID: UUID, email: String?, displayName: String?, completeProfile: Bool) {
        currentUserID = userID
        if profiles[userID] == nil {
            profiles[userID] = UserProfile(id: userID, displayName: displayName ?? "", avatarPath: nil, city: nil, district: nil,
                                           preferredCategories: [], language: .en, accessibilityNeeds: [], phone: nil,
                                           identityStatus: completeProfile ? .verifiedUnique : .none,
                                           onboardingCompletedAt: completeProfile ? clock() : nil)
            balances[userID] = balances[userID] ?? 0
            ledgers[userID] = ledgers[userID] ?? []
            preferencesByUser[userID] = NotificationPreferences()
        }
    }

    func signOut() { currentUserID = nil }

    /// Test seam: set a wallet balance directly (development backend only).
    func setBalance(_ minorUnits: Int64, for userID: UUID) { balances[userID] = minorUnits }

    func deleteCurrentUser() {
        guard let userID = currentUserID else { return }
        profiles[userID] = nil
        saved[userID] = nil
        notificationsByUser[userID] = nil
        identityDigests = identityDigests.filter { $0.value != userID }
        currentUserID = nil
    }

    private func requireUser() throws -> UUID {
        guard let currentUserID else { throw ZunoError.notAuthenticated }
        return currentUserID
    }

    private func latency() async {
        try? await Task.sleep(for: simulatedLatency)
    }

    // MARK: Helpers

    private static func stableUUID(_ base: UUID, _ index: Int) -> UUID {
        var bytes = withUnsafeBytes(of: base.uuid) { Array($0) }
        bytes[15] = UInt8(truncatingIfNeeded: Int(bytes[15]) + index + 1)
        return bytes.withUnsafeBytes { UUID(uuid: $0.load(as: uuid_t.self)) }
    }

    private static let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    static func reference(prefix: String) -> String {
        "\(prefix)-" + String((0..<8).map { _ in crockford.randomElement()! })
    }

    private static func ticketCode() -> String {
        let chars = (0..<8).map { _ in crockford.randomElement()! }
        return "ZN-\(String(chars[0..<4]))-\(String(chars[4..<8]))"
    }

    private static func qrToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @discardableResult
    private func issueTicket(for registration: DevRegistration, tierName: String, orderID: UUID?, holder: String) -> Ticket {
        let event = events[registration.eventID]!.summary
        let ticket = Ticket(
            id: UUID(), code: Self.ticketCode(), qrPayload: "zuno:t:\(Self.qrToken())", status: .valid, tierName: tierName,
            attendeeName: holder, issuedAt: registration.createdAt, checkedInAt: nil, registrationReference: registration.reference,
            orderID: orderID,
            event: TicketEventInfo(id: event.id, title: event.title, startsAt: event.startsAt, endsAt: event.endsAt,
                                   venueName: event.venueName, city: event.city, cover: event.cover, coverAlt: event.coverAlt,
                                   status: event.status, categoryID: event.categoryID)
        )
        tickets.append(DevTicket(ticket: ticket, userID: registration.userID))
        return ticket
    }

    private func checkInDirect(ticketID: UUID, at date: Date) {
        guard let index = tickets.firstIndex(where: { $0.ticket.id == ticketID }) else { return }
        tickets[index].ticket.status = .checkedIn
        tickets[index].ticket.checkedInAt = date
    }

    private func refreshSeats(_ eventID: UUID) {
        guard var event = events[eventID] else { return }
        if !event.summary.isFree {
            event.seatsTaken = event.tiers.reduce(0) { $0 + ($1.quantity - $1.remaining) }
            event.summary.minPrice = event.tiers.map(\.price).min()
        }
        event.summary.seatsRemaining = max(event.summary.capacity - event.seatsTaken, 0)
        events[eventID] = event
    }

    private func postLedger(_ userID: UUID, type: WalletEntryType, amount: Int64, description: String, referenceID: UUID?) {
        let balance = (balances[userID] ?? 0) + amount
        balances[userID] = balance
        ledgers[userID, default: []].insert(
            WalletTransaction(id: UUID(), type: type, amount: .lkr(amount), balanceAfter: .lkr(balance), status: .posted,
                              description: description, referenceType: nil, referenceID: referenceID, createdAt: clock()),
            at: 0
        )
    }

    private func notify(_ userID: UUID, kind: NotificationKind, title: String, body: String, eventID: UUID?) {
        notificationsByUser[userID, default: []].insert(
            AppNotification(id: UUID(), kind: kind, title: title, body: body, eventID: eventID, readAt: nil, createdAt: clock()), at: 0
        )
        notificationContinuations[userID]?.yield(())
    }

    private func activeRegistration(userID: UUID, eventID: UUID) -> DevRegistration? {
        registrations.first { $0.userID == userID && $0.eventID == eventID && $0.status != .cancelled }
    }

    private func holderName(_ userID: UUID) -> String {
        let name = profiles[userID]?.displayName ?? ""
        return name.isEmpty ? String(localized: "Zuno attendee") : name
    }
}

// MARK: - EventRepository

extension DevelopmentBackend: EventRepository {
    func categories() async throws -> [EventCategory] { categories }

    func searchEvents(query: String?, filters: EventFilters, limit: Int) async throws -> [EventSummary] {
        await latency()
        let now = clock()
        var results = events.values.map(\.summary).filter { filters.matches($0, now: now) }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = EventSearch.rank(results.filter { EventSearch.matches($0, query: query, now: now) }, query: query)
        } else {
            results.sort { $0.startsAt < $1.startsAt }
        }
        return Array(results.prefix(limit))
    }

    func eventDetail(id: UUID) async throws -> EventDetail {
        await latency()
        guard let event = events[id] else { throw ZunoError.notFound }
        let userID = currentUserID
        let registration = userID.flatMap { activeRegistration(userID: $0, eventID: id) }
        let organizerOwner = organizerOwners[event.summary.organizerID]
        return EventDetail(
            summary: event.summary, description: event.description, addressLine: event.addressLine, onlineURL: event.onlineURL,
            agenda: event.agenda, speakers: event.speakers, refundPolicy: event.refundPolicy,
            registrationOpensAt: nil,
            // Long-running exhibitions stay open until they end; one-off events close at the start.
            registrationClosesAt: event.summary.isMultiDay ? event.summary.endsAt : event.summary.startsAt,
            organizerVerified: organizers[event.summary.organizerID]?.verification == .verified,
            tiers: event.tiers, questions: event.questions, gallery: [],
            viewer: ViewerState(
                isSaved: userID.map { saved[$0, default: []].contains(id) } ?? false,
                registrationStatus: registration?.status, registrationID: registration?.id,
                isOrganizer: userID != nil && organizerOwner == userID
            )
        )
    }

    func savedEventIDs() async throws -> Set<UUID> {
        guard let userID = currentUserID else { return [] }
        return saved[userID, default: []]
    }

    func setSaved(_ isSaved: Bool, eventID: UUID) async throws {
        let userID = try requireUser()
        if isSaved { saved[userID, default: []].insert(eventID) } else { saved[userID, default: []].remove(eventID) }
    }

    func savedEvents() async throws -> [EventSummary] {
        guard let userID = currentUserID else { return [] }
        return saved[userID, default: []].compactMap { events[$0]?.summary }.sorted { $0.startsAt < $1.startsAt }
    }

    func followedOrganizerIDs() async throws -> Set<UUID> {
        guard let userID = currentUserID else { return [] }
        return followed[userID, default: []]
    }

    func setFollowing(_ following: Bool, organizerID: UUID) async throws {
        let userID = try requireUser()
        if following { followed[userID, default: []].insert(organizerID) } else { followed[userID, default: []].remove(organizerID) }
    }
}

// MARK: - RegistrationRepository

extension DevelopmentBackend: RegistrationRepository {
    private func evaluate(eventID: UUID, userID: UUID) throws -> (FreeRegistrationPolicy.Evaluation, DevEvent, Int) {
        guard let event = events[eventID] else { throw ZunoError.notFound }
        let now = clock()
        let month = FreeRegistrationPolicy.monthKey(for: now)
        let used = allowanceUsed[userID]?[month] ?? 0
        let offered = registrations.filter { $0.eventID == eventID && $0.status == .offered && $0.userID != userID }.count
        let evaluation = policy.evaluate(
            isFreeEvent: event.summary.isFree,
            registrationOpen: now < event.summary.startsAt || (event.summary.isMultiDay && now < event.summary.endsAt),
            alreadyRegistered: registrations.contains { $0.userID == userID && $0.eventID == eventID && $0.status == .confirmed },
            seatsRemaining: event.summary.capacity - event.seatsTaken - offered,
            identityVerified: profiles[userID]?.identityStatus == .verifiedUnique,
            usedThisMonth: used,
            walletBalance: .lkr(balances[userID] ?? 0)
        )
        return (evaluation, event, used)
    }

    func quoteFreeRegistration(eventID: UUID) async throws -> FreeRegistrationQuote {
        await latency()
        let userID = try requireUser()
        let (evaluation, event, used) = try evaluate(eventID: eventID, userID: userID)
        return FreeRegistrationQuote(
            allowanceLimit: policy.monthlyAllowance, allowanceUsed: used, allowanceRemaining: policy.remaining(usedThisMonth: used),
            fee: evaluation.fee, walletBalance: .lkr(balances[userID] ?? 0), canRegister: evaluation.canRegister,
            reason: evaluation.reason, seatsRemaining: max(event.summary.capacity - event.seatsTaken, 0),
            month: FreeRegistrationPolicy.monthKey(for: clock())
        )
    }

    /// Mirrors `register_for_free_event`: everything below either fully applies or not at all
    /// (the actor serialises access, standing in for the row locks).
    func registerFree(eventID: UUID, answers: [RegistrationAnswer], expectedFee: Money, idempotencyKey: String) async throws -> RegistrationConfirmation {
        await latency()
        let userID = try requireUser()
        if let replay = registrationReplays["\(userID)-\(idempotencyKey)"] { return replay }
        let (evaluation, event, used) = try evaluate(eventID: eventID, userID: userID)
        if let reason = evaluation.reason { throw ZunoError.registration(reason) }
        guard evaluation.fee == expectedFee else { throw ZunoError.feeChanged }
        let answerMap = Dictionary(answers.map { ($0.questionID, $0.value) }, uniquingKeysWith: { $1 })
        guard AnswerValidation.missingRequired(questions: event.questions, answers: answerMap).isEmpty else { throw ZunoError.answersInvalid }

        let month = FreeRegistrationPolicy.monthKey(for: clock())
        let registration = DevRegistration(id: UUID(), eventID: eventID, userID: userID, status: .confirmed, kind: .free, fee: evaluation.fee,
                                           reference: Self.reference(prefix: "ZR"), createdAt: clock())
        if evaluation.fee.minorUnits > 0 {
            postLedger(userID, type: .freeRegistrationFee, amount: -evaluation.fee.minorUnits,
                       description: "Free registration beyond monthly allowance — \(event.summary.title)", referenceID: registration.id)
        }
        registrations.removeAll { $0.userID == userID && $0.eventID == eventID && $0.status == .offered }
        registrations.append(registration)
        allowanceUsed[userID, default: [:]][month] = used + 1
        events[eventID]?.seatsTaken += 1
        refreshSeats(eventID)
        let ticket = issueTicket(for: registration, tierName: String(localized: "Free admission"), orderID: nil, holder: holderName(userID))
        notify(userID, kind: .registrationConfirmed, title: "You're registered for \(event.summary.title)",
               body: "Your ticket \(ticket.code) is ready in the Tickets tab.", eventID: eventID)
        let confirmation = RegistrationConfirmation(
            registrationID: registration.id, reference: registration.reference, ticketID: ticket.id, fee: evaluation.fee,
            allowanceRemaining: policy.remaining(usedThisMonth: used + 1), walletBalance: .lkr(balances[userID] ?? 0), status: .confirmed
        )
        registrationReplays["\(userID)-\(idempotencyKey)"] = confirmation
        return confirmation
    }

    func joinWaitlist(eventID: UUID) async throws -> WaitlistConfirmation {
        await latency()
        let userID = try requireUser()
        guard let event = events[eventID] else { throw ZunoError.notFound }
        // Mirrors join_waitlist: full free events only.
        guard event.summary.isFree else { throw ZunoError.registration(.notFreeEvent) }
        guard event.summary.capacity - event.seatsTaken <= 0 else { throw ZunoError.server(code: "seats_available", message: nil) }
        if let existing = activeRegistration(userID: userID, eventID: eventID) {
            if existing.status == .confirmed { throw ZunoError.registration(.alreadyRegistered) }
            let position = registrations.filter { $0.eventID == eventID && $0.status == .waitlisted }.firstIndex { $0.id == existing.id } ?? 0
            return WaitlistConfirmation(registrationID: existing.id, position: position + 1)
        }
        let registration = DevRegistration(id: UUID(), eventID: eventID, userID: userID, status: .waitlisted,
                                           kind: .free, fee: .zero,
                                           reference: Self.reference(prefix: "ZR"), createdAt: clock())
        registrations.append(registration)
        let position = registrations.filter { $0.eventID == eventID && $0.status == .waitlisted }.count
        notify(userID, kind: .waitlistMovement, title: "You're on the waitlist",
               body: "We'll let you know if a place opens for \(events[eventID]!.summary.title).", eventID: eventID)
        return WaitlistConfirmation(registrationID: registration.id, position: position)
    }

    func cancelRegistration(id: UUID) async throws {
        await latency()
        let userID = try requireUser()
        guard let index = registrations.firstIndex(where: { $0.id == id && $0.userID == userID }) else { throw ZunoError.notFound }
        let wasConfirmed = registrations[index].status == .confirmed
        let eventID = registrations[index].eventID
        registrations[index].status = .cancelled
        for ticketIndex in tickets.indices where tickets[ticketIndex].ticket.registrationReference == registrations[index].reference {
            tickets[ticketIndex].ticket.status = .cancelled
        }
        guard wasConfirmed else { return }
        events[eventID]?.seatsTaken -= 1
        refreshSeats(eventID)
        if let next = registrations.firstIndex(where: { $0.eventID == eventID && $0.status == .waitlisted }) {
            registrations[next].status = .offered
            notify(registrations[next].userID, kind: .waitlistMovement, title: "A place opened up",
                   body: "Register now for \(events[eventID]!.summary.title) — the place is held for 12 hours.", eventID: eventID)
        }
    }

    func registrations() async throws -> [RegistrationRecord] {
        let userID = try requireUser()
        return registrations.filter { $0.userID == userID }.compactMap { registration in
            guard let event = events[registration.eventID]?.summary else { return nil }
            return RegistrationRecord(
                id: registration.id,
                event: TicketEventInfo(id: event.id, title: event.title, startsAt: event.startsAt, endsAt: event.endsAt, venueName: event.venueName,
                                       city: event.city, cover: event.cover, coverAlt: event.coverAlt, status: event.status, categoryID: event.categoryID),
                status: registration.status, kind: registration.kind, fee: registration.fee, reference: registration.reference,
                createdAt: registration.createdAt
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - CheckoutRepository

extension DevelopmentBackend: CheckoutRepository {
    func createCheckout(_ request: CheckoutRequest) async throws -> CheckoutSession {
        await latency()
        let userID = try requireUser()
        expireStaleOrders()
        if let replay = checkoutReplays["\(userID)-\(request.idempotencyKey)"] { return replay }
        guard SriLankaLocations.normalizedMobile(request.phone) != nil else {
            throw ZunoError.server(code: "invalid_phone", message: String(localized: "Enter a Sri Lankan mobile number, e.g. 077 123 4567."))
        }
        let now = clock()
        let orderID = UUID()
        let summary: OrderSummary
        var kind: OrderKind = .ticket
        var eventID: UUID?
        var items: [CheckoutItem] = []
        var answers: [RegistrationAnswer] = []
        switch request.purpose {
        case .tickets(let id, let requestItems, let requestAnswers):
            guard var event = events[id] else { throw ZunoError.notFound }
            // Price from server-side tiers only; the request carries tier IDs and quantities.
            let lines = try requestItems.map { item -> OrderPricing.Line in
                guard let tier = event.tiers.first(where: { $0.id == item.tierID }) else { throw ZunoError.notFound }
                return OrderPricing.Line(tier: tier, quantity: item.quantity)
            }
            do {
                summary = try OrderPricing.summarize(lines, commissionBps: commissionBps, now: now)
            } catch OrderPricing.PricingError.insufficientInventory {
                throw ZunoError.registration(.soldOut)
            } catch {
                throw ZunoError.server(code: "invalid_order", message: String(localized: "Those tickets aren't available in that quantity."))
            }
            // Reserve inventory for the hold period.
            for item in requestItems {
                if let index = event.tiers.firstIndex(where: { $0.id == item.tierID }) { event.tiers[index].remaining -= item.quantity }
            }
            events[id] = event
            refreshSeats(id)
            eventID = id
            items = requestItems
            answers = requestAnswers
        case .walletTopUp(let amount):
            guard WalletTopUpPolicy.validate(amount) else {
                throw ZunoError.server(code: "invalid_amount", message: String(localized: "Top-ups must be between LKR 100 and LKR 50,000."))
            }
            kind = .walletTopUp
            summary = OrderSummary(lines: [OrderLine(label: String(localized: "Wallet top-up"), quantity: 1, unitPrice: amount, amount: amount)],
                                   subtotal: amount, commission: .zero, total: amount)
        case .eventCreationFee(let id):
            kind = .eventCreationFee
            eventID = id
            let fee = Money.rupees(1_000)
            summary = OrderSummary(lines: [OrderLine(label: String(localized: "Event creation fee"), quantity: 1, unitPrice: fee, amount: fee)],
                                   subtotal: fee, commission: .zero, total: fee)
        }
        let expires = now.addingTimeInterval(15 * 60)
        orders[orderID] = DevOrder(
            snapshot: OrderSnapshot(id: orderID, kind: kind, status: .pending, total: summary.total, eventID: eventID, paidAt: nil, createdAt: now),
            userID: userID, items: items, answers: answers, summary: summary, expiresAt: expires
        )
        if kind == .walletTopUp {
            ledgers[userID, default: []].insert(WalletTransaction(id: orderID, type: .topup, amount: summary.total, balanceAfter: nil, status: .pending,
                                                                  description: "PayHere top-up", referenceType: "order", referenceID: orderID, createdAt: now), at: 0)
        }
        let session = CheckoutSession(orderID: orderID, expiresAt: expires, summary: summary, payment: .developmentSimulator)
        checkoutReplays["\(userID)-\(request.idempotencyKey)"] = session
        return session
    }

    func order(id: UUID) async throws -> OrderSnapshot {
        expireStaleOrders()
        guard let order = orders[id], order.userID == currentUserID else { throw ZunoError.notFound }
        return order.snapshot
    }

    /// Same semantics as `apply_payhere_notification`: idempotent per (order, status),
    /// only pending orders transition, tickets/top-ups only after a "verified" success.
    func simulateGatewayNotification(orderID: UUID, statusCode: Int) async throws {
        try? await Task.sleep(for: .milliseconds(600))
        let key = "\(orderID)-\(statusCode)"
        guard !processedGatewayEvents.contains(key) else { return }
        processedGatewayEvents.insert(key)
        guard var order = orders[orderID], order.snapshot.status == .pending else { return }
        switch statusCode {
        case 2:
            order.snapshot.status = .paid
            order.snapshot.paidAt = clock()
            fulfil(order)
        case -1:
            order.snapshot.status = .cancelled
            release(order)
        case -2, -3:
            order.snapshot.status = .failed
            release(order)
        default: // treat anything else as expiry for the simulator
            order.snapshot.status = .expired
            release(order)
        }
        orders[orderID] = order
        if order.snapshot.status != .paid {
            notify(order.userID, kind: .paymentStatus, title: String(localized: "Payment not completed"),
                   body: String(localized: "Your order wasn't charged. You can try again any time."), eventID: order.snapshot.eventID)
        }
    }

    private func fulfil(_ order: DevOrder) {
        switch order.snapshot.kind {
        case .ticket:
            guard let eventID = order.snapshot.eventID, let event = events[eventID] else { return }
            let registration = DevRegistration(id: UUID(), eventID: eventID, userID: order.userID, status: .confirmed, kind: .paid, fee: .zero,
                                               reference: Self.reference(prefix: "ZR"), createdAt: clock())
            registrations.removeAll { $0.userID == order.userID && $0.eventID == eventID && ($0.status == .offered || $0.status == .waitlisted) }
            registrations.append(registration)
            for item in order.items {
                let tierName = event.tiers.first { $0.id == item.tierID }?.name ?? ""
                for _ in 0..<item.quantity {
                    issueTicket(for: registration, tierName: tierName, orderID: order.snapshot.id, holder: holderName(order.userID))
                }
            }
            notify(order.userID, kind: .ticketIssued, title: "Your tickets for \(event.summary.title)",
                   body: "Payment confirmed. Your tickets are in the Tickets tab.", eventID: eventID)
        case .walletTopUp:
            ledgers[order.userID]?.removeAll { $0.id == order.snapshot.id }
            postLedger(order.userID, type: .topup, amount: order.snapshot.total.minorUnits, description: "PayHere top-up", referenceID: order.snapshot.id)
            notify(order.userID, kind: .paymentStatus, title: "Top-up received",
                   body: "\(ZunoFormat.currency(order.snapshot.total)) was added to your wallet.", eventID: nil)
        case .eventCreationFee:
            if let eventID = order.snapshot.eventID { events[eventID]?.creationFeePaid = true }
            notify(order.userID, kind: .paymentStatus, title: "Event fee paid",
                   body: "You can now publish your event once it passes validation.", eventID: order.snapshot.eventID)
        }
    }

    private func release(_ order: DevOrder) {
        if order.snapshot.kind == .ticket, let eventID = order.snapshot.eventID, var event = events[eventID] {
            for item in order.items {
                if let index = event.tiers.firstIndex(where: { $0.id == item.tierID }) { event.tiers[index].remaining += item.quantity }
            }
            events[eventID] = event
            refreshSeats(eventID)
        }
        if order.snapshot.kind == .walletTopUp, let index = ledgers[order.userID]?.firstIndex(where: { $0.id == order.snapshot.id }) {
            ledgers[order.userID]?[index].status = .failed
        }
    }

    private func expireStaleOrders() {
        let now = clock()
        for (id, order) in orders where order.snapshot.status == .pending && order.expiresAt <= now {
            var expired = order
            expired.snapshot.status = .expired
            orders[id] = expired
            release(order)
        }
    }
}

// MARK: - Wallet & tickets

extension DevelopmentBackend: WalletRepository, TicketRepository {
    func summary() async throws -> WalletSummary {
        await latency()
        let userID = try requireUser()
        let month = FreeRegistrationPolicy.monthKey(for: clock())
        let used = allowanceUsed[userID]?[month] ?? 0
        let pending = ledgers[userID, default: []].filter { $0.status == .pending }.reduce(Int64(0)) { $0 + $1.amount.minorUnits }
        return WalletSummary(balance: .lkr(balances[userID] ?? 0), allowanceLimit: policy.monthlyAllowance, allowanceUsed: used,
                             allowanceRemaining: policy.remaining(usedThisMonth: used), extraFee: policy.extraFee, month: month,
                             pendingTopUps: .lkr(pending))
    }

    func transactions() async throws -> [WalletTransaction] {
        let userID = try requireUser()
        return ledgers[userID, default: []].sorted { $0.createdAt > $1.createdAt }
    }

    func tickets() async throws -> [Ticket] {
        await latency()
        let userID = try requireUser()
        return tickets.filter { $0.userID == userID }.map(\.ticket)
    }
}

// MARK: - Profile

extension DevelopmentBackend: ProfileRepository {
    func currentProfile() async throws -> UserProfile? {
        await latency()
        let userID = try requireUser()
        return profiles[userID]
    }

    func saveProfile(_ draft: ProfileDraft, markOnboardingComplete: Bool) async throws -> UserProfile {
        await latency()
        let userID = try requireUser()
        var profile = profiles[userID] ?? UserProfile(id: userID, displayName: "", avatarPath: nil, city: nil, district: nil,
                                                      preferredCategories: [], language: .en, accessibilityNeeds: [], phone: nil,
                                                      identityStatus: .none, onboardingCompletedAt: nil)
        profile.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.avatarPath = draft.avatarPath ?? profile.avatarPath
        profile.city = draft.city
        profile.district = draft.district
        profile.preferredCategories = draft.preferredCategories.sorted()
        profile.language = draft.language
        profile.accessibilityNeeds = Array(draft.accessibilityNeeds)
        profile.phone = SriLankaLocations.normalizedMobile(draft.phone)
        if markOnboardingComplete && profile.onboardingCompletedAt == nil { profile.onboardingCompletedAt = clock() }
        profiles[userID] = profile
        return profile
    }

    func uploadAvatar(_ jpegData: Data) async throws -> String {
        let userID = try requireUser()
        return "\(userID.uuidString.lowercased())/avatar.jpg"
    }

    /// Simulates the Edge Function's canonicalisation + digest lookup (no raw value is kept).
    func submitNationalIdentifier(_ value: String) async throws -> IdentityCheckResult {
        await latency()
        let userID = try requireUser()
        let normalized = NICInput.normalizeForTransmission(value)
        guard let format = NICInput.format(of: normalized) else {
            throw ZunoError.server(code: "invalid_format", message: String(localized: "That doesn't look like a Sri Lankan NIC number."))
        }
        let canonical: String = switch format {
        case .new: normalized
        case .old: "19" + normalized.prefix(5) + "0" + normalized.dropFirst(5).prefix(4)
        }
        if let owner = identityDigests[canonical], owner != userID { return .duplicate }
        identityDigests[canonical] = userID
        profiles[userID]?.identityStatus = .verifiedUnique
        return .verifiedUnique
    }
}

// MARK: - Notifications

extension DevelopmentBackend: NotificationRepository {
    func notifications() async throws -> [AppNotification] {
        guard let userID = currentUserID else { return [] }
        return notificationsByUser[userID, default: []]
    }

    func markRead(ids: [UUID]) async throws {
        let userID = try requireUser()
        for index in notificationsByUser[userID, default: []].indices where ids.contains(notificationsByUser[userID]![index].id) {
            notificationsByUser[userID]![index].readAt = notificationsByUser[userID]![index].readAt ?? clock()
        }
    }

    func markAllRead() async throws {
        let userID = try requireUser()
        for index in notificationsByUser[userID, default: []].indices where notificationsByUser[userID]![index].readAt == nil {
            notificationsByUser[userID]![index].readAt = clock()
        }
    }

    func preferences() async throws -> NotificationPreferences {
        let userID = try requireUser()
        return preferencesByUser[userID] ?? NotificationPreferences()
    }

    func updatePreferences(_ preferences: NotificationPreferences) async throws {
        let userID = try requireUser()
        preferencesByUser[userID] = preferences
    }

    func registerPushToken(_ token: String, environment: String) async throws {}

    func changes() async -> AsyncStream<Void> {
        guard let userID = currentUserID else { return AsyncStream { $0.finish() } }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        notificationContinuations[userID] = continuation
        return stream
    }
}

// MARK: - Organizer

extension DevelopmentBackend: OrganizerRepository {
    private func ownedOrganizer() -> OrganizerProfile? {
        guard let userID = currentUserID, let id = organizerOwners.first(where: { $0.value == userID })?.key else { return nil }
        return organizers[id]
    }

    func dashboard() async throws -> OrganizerDashboard? {
        await latency()
        guard let organizer = ownedOrganizer() else { return nil }
        let rows = events.values.filter { $0.summary.organizerID == organizer.id }.map { event in
            OrganizerEventRow(
                event: event.summary,
                registrations: registrations.filter { $0.eventID == event.summary.id && $0.status == .confirmed }.count,
                checkedIn: tickets.filter { $0.ticket.event.id == event.summary.id && $0.ticket.status == .checkedIn }.count
            )
        }.sorted { $0.event.startsAt < $1.event.startsAt }
        let totals = rows.reduce(SalesTotals.zero) { partial, row in
            let stats = salesTotals(for: row.event.id)
            return SalesTotals(gross: partial.gross + stats.gross, commission: partial.commission + stats.commission, net: partial.net + stats.net)
        }
        return OrganizerDashboard(organizer: organizer, events: rows, totals: totals)
    }

    private func salesTotals(for eventID: UUID) -> SalesTotals {
        guard let event = events[eventID], !event.summary.isFree else { return .zero }
        let gross = event.tiers.reduce(Int64(0)) { $0 + $1.price.minorUnits * Int64($1.quantity - $1.remaining) }
        let commission = CommissionPolicy.commission(onSubtotal: gross, basisPoints: commissionBps)
        return SalesTotals(gross: .lkr(gross), commission: .lkr(commission), net: .lkr(gross - commission))
    }

    func createOrganizerProfile(_ draft: OrganizerProfileDraft) async throws -> OrganizerProfile {
        await latency()
        let userID = try requireUser()
        guard draft.isValid else { throw ZunoError.server(code: "validation_failed", message: nil) }
        let profile = OrganizerProfile(id: UUID(), name: draft.name, slug: draft.slug, bio: draft.bio, logoPath: nil,
                                       contactEmail: draft.contactEmail, verification: .pending)
        organizers[profile.id] = profile
        organizerOwners[profile.id] = userID
        return profile
    }

    func venues() async throws -> [Venue] {
        guard let organizer = ownedOrganizer() else { return [] }
        return venues.values.filter { venue in events.values.contains { $0.summary.organizerID == organizer.id && $0.summary.venueName == venue.name } || true }
            .sorted { $0.name < $1.name }
    }

    func createVenue(name: String, addressLine: String, city: String) async throws -> Venue {
        let place = SriLankaLocations.place(named: city)
        let venue = Venue(id: UUID(), name: name, addressLine: addressLine, city: city, district: place?.district ?? city, location: place?.location)
        venues[venue.id] = venue
        return venue
    }

    func saveEventDraft(_ draft: EventDraft) async throws -> EventDraft {
        await latency()
        guard let organizer = ownedOrganizer(), organizer.id == draft.organizerID else { throw ZunoError.server(code: "not_owner", message: nil) }
        if let existing = events[draft.id], existing.summary.status != .draft {
            throw ZunoError.server(code: "not_editable", message: String(localized: "Published events can't be edited here."))
        }
        let venue = draft.venueID.flatMap { venues[$0] }
        let tiers = draft.isFree ? [] : draft.tiers.map {
            TicketTier(id: $0.id, name: $0.name, description: $0.description, price: $0.price, quantity: $0.quantity, remaining: $0.quantity,
                       maxPerOrder: $0.maxPerOrder, salesStartAt: $0.salesStartAt, salesEndAt: $0.salesEndAt ?? draft.startsAt, onSale: true)
        }
        let capacity = draft.isFree ? draft.capacity : max(draft.capacity, tiers.reduce(0) { $0 + $1.quantity })
        let summary = EventSummary(
            id: draft.id, title: draft.title, summary: draft.summary, categoryID: draft.categoryID,
            categoryName: categories.first { $0.id == draft.categoryID }?.name ?? draft.categoryID,
            organizerID: organizer.id, organizerName: organizer.name, venueName: venue?.name, city: venue?.city, district: venue?.district,
            location: venue?.location, university: draft.university.isEmpty ? nil : draft.university, format: draft.format,
            startsAt: draft.startsAt, endsAt: draft.endsAt, isFree: draft.isFree, minPrice: tiers.map(\.price).min(),
            capacity: capacity, seatsRemaining: capacity,
            cover: draft.coverPath.map { $0.hasPrefix("seed-") ? .bundled(name: $0) : .bundled(name: "seed-climate-ai-hackathon") },
            coverAlt: draft.coverAlt, tags: draft.tags, status: .draft
        )
        let feePaid = events[draft.id]?.creationFeePaid ?? false
        events[draft.id] = DevEvent(
            summary: summary, description: draft.description, addressLine: venue?.addressLine, onlineURL: URL(string: draft.onlineURL),
            agenda: draft.agenda, speakers: draft.speakers, refundPolicy: draft.refundPolicy, tiers: tiers,
            questions: draft.questions.map { RegistrationQuestion(id: $0.id, prompt: $0.prompt, kind: $0.kind, options: $0.options, required: $0.required) },
            seatsTaken: 0, creationFeePaid: feePaid
        )
        var saved = draft
        saved.creationFeePaid = feePaid
        saved.status = .draft
        return saved
    }

    func eventDraft(id: UUID) async throws -> EventDraft {
        guard let event = events[id] else { throw ZunoError.notFound }
        var draft = EventDraft(id: id, organizerID: event.summary.organizerID)
        draft.title = event.summary.title
        draft.summary = event.summary.summary
        draft.description = event.description
        draft.categoryID = event.summary.categoryID
        draft.format = event.summary.format
        draft.venueID = venues.values.first { $0.name == event.summary.venueName }?.id
        draft.onlineURL = event.onlineURL?.absoluteString ?? ""
        draft.startsAt = event.summary.startsAt
        draft.endsAt = event.summary.endsAt
        draft.capacity = event.summary.capacity
        draft.isFree = event.summary.isFree
        draft.university = event.summary.university ?? ""
        draft.tags = event.summary.tags
        if case .bundled(let name)? = event.summary.cover { draft.coverPath = name }
        draft.coverAlt = event.summary.coverAlt ?? ""
        draft.agenda = event.agenda
        draft.speakers = event.speakers
        draft.refundPolicy = event.refundPolicy
        draft.tiers = event.tiers.map { TierDraft(id: $0.id, name: $0.name, description: $0.description, price: $0.price, quantity: $0.quantity, maxPerOrder: $0.maxPerOrder) }
        draft.questions = event.questions.map { QuestionDraft(id: $0.id, prompt: $0.prompt, kind: $0.kind, options: $0.options, required: $0.required) }
        draft.status = event.summary.status
        draft.creationFeePaid = event.creationFeePaid
        return draft
    }

    func uploadEventImage(eventID: UUID, organizerID: UUID, jpegData: Data) async throws -> String {
        await latency()
        return "seed-climate-ai-hackathon"
    }

    func submitForPublish(eventID: UUID) async throws {
        await latency()
        guard let organizer = ownedOrganizer() else { throw ZunoError.server(code: "not_owner", message: nil) }
        guard organizer.verification == .verified else {
            throw ZunoError.server(code: "organizer_not_verified", message: String(localized: "Your organizer profile is still being verified."))
        }
        guard let event = events[eventID] else { throw ZunoError.notFound }
        guard event.creationFeePaid else {
            throw ZunoError.server(code: "creation_fee_unpaid", message: String(localized: "Pay the event creation fee before publishing."))
        }
        let draft = try await eventDraft(id: eventID)
        let issues = draft.validationIssues(now: clock())
        guard issues.isEmpty else {
            throw ZunoError.server(code: "validation_failed", message: issues.map(\.message).joined(separator: "\n"))
        }
        events[eventID]?.summary.status = .published
    }

    func stats(eventID: UUID) async throws -> OrganizerEventStats {
        await latency()
        guard let event = events[eventID] else { throw ZunoError.notFound }
        let totals = salesTotals(for: eventID)
        let eventTickets = tickets.filter { $0.ticket.event.id == eventID }
        return OrganizerEventStats(
            capacity: event.summary.capacity,
            registrations: registrations.filter { $0.eventID == eventID && $0.status == .confirmed }.count,
            waitlisted: registrations.filter { $0.eventID == eventID && $0.status == .waitlisted }.count,
            checkedIn: eventTickets.filter { $0.ticket.status == .checkedIn }.count,
            ticketsSold: event.summary.isFree ? 0 : event.tiers.reduce(0) { $0 + $1.quantity - $1.remaining },
            gross: totals.gross, commission: totals.commission, net: totals.net,
            byTier: event.tiers.map { tier in
                let sold = tier.quantity - tier.remaining
                return TierSales(tierID: tier.id, name: tier.name, sold: sold, quantity: tier.quantity, gross: tier.price * sold)
            }
        )
    }

    func attendees(eventID: UUID) async throws -> [AttendeeRow] {
        await latency()
        return tickets.filter { $0.ticket.event.id == eventID }.map {
            AttendeeRow(ticketID: $0.ticket.id, attendeeName: $0.ticket.attendeeName, tierName: $0.ticket.tierName, status: $0.ticket.status,
                        checkedInAt: $0.ticket.checkedInAt, registrationReference: $0.ticket.registrationReference)
        }.sorted { $0.attendeeName < $1.attendeeName }
    }

    func settlements() async throws -> [SettlementRow] {
        guard let organizer = ownedOrganizer() else { return [] }
        return events.values.filter { $0.summary.organizerID == organizer.id && !$0.summary.isFree }.map { event in
            let totals = salesTotals(for: event.summary.id)
            return SettlementRow(eventID: event.summary.id, title: event.summary.title, gross: totals.gross, commission: totals.commission,
                                 net: totals.net, payoutStatus: event.summary.hasEnded(now: clock()) ? .scheduled : .unsettled)
        }
    }

    func sendUpdate(eventID: UUID, kind: EventUpdateKind, message: String) async throws -> Int {
        await latency()
        guard let event = events[eventID] else { throw ZunoError.notFound }
        let recipients = Set(registrations.filter { $0.eventID == eventID && $0.status == .confirmed }.map(\.userID))
        let notificationKind: NotificationKind = switch kind {
        case .general: .organizerUpdate
        case .venueChange: .venueChange
        case .scheduleChange: .scheduleChange
        }
        for userID in recipients {
            notify(userID, kind: notificationKind, title: "\(kind.title): \(event.summary.title)", body: message, eventID: eventID)
        }
        return recipients.count
    }

    func exportAttendees(eventID: UUID) async throws -> ExportedFile {
        let rows = try await attendees(eventID: eventID)
        func escape(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" : value
        }
        let header = "reference,attendee_name,tier,status,checked_in_at"
        let lines = rows.map { row in
            [row.registrationReference, row.attendeeName, row.tierName, row.status.rawValue,
             row.checkedInAt.map { $0.formatted(.iso8601) } ?? ""].map(escape).joined(separator: ",")
        }
        let slug = events[eventID]?.summary.title.lowercased().replacingOccurrences(of: " ", with: "-") ?? "event"
        return ExportedFile(filename: "zuno-attendees-\(slug).csv", contents: ([header] + lines).joined(separator: "\n"))
    }

    /// Development stand-in for the AI copilot. Instructions containing "refuse",
    /// "malformed" or "timeout" exercise the corresponding failure paths.
    func generateDraft(eventID: UUID, kind: AIDraftKind, instructions: String?) async throws -> AIDraftResult {
        try await Task.sleep(for: .seconds(1.2))
        let lowered = instructions?.lowercased() ?? ""
        if lowered.contains("timeout") { throw ZunoError.server(code: "ai_timeout", message: nil) }
        if lowered.contains("refuse") { throw ZunoError.server(code: "ai_refused", message: nil) }
        if lowered.contains("malformed") { throw ZunoError.server(code: "ai_malformed", message: nil) }
        guard let event = events[eventID] else { throw ZunoError.notFound }
        let start = event.summary.startsAt
        let hours = max(event.summary.endsAt.timeIntervalSince(start) / 3600, 1)
        switch kind {
        case .agenda:
            let blocks: [(Double, String, String)] = [
                (0, "Arrival and welcome", "Check-in, name badges and a short introduction."),
                (0.15, "Opening talk", "What attendees will get out of \(event.summary.title)."),
                (0.4, "Hands-on session", "Small groups work through the main activity with facilitators."),
                (0.85, "Wrap-up and next steps", "Highlights, feedback and how to stay involved."),
            ]
            let agenda = blocks.enumerated().map { index, block in
                let s = start.addingTimeInterval(block.0 * hours * 3600)
                let nextFraction = index + 1 < blocks.count ? blocks[index + 1].0 : 1
                return AgendaItem(startsAt: s, endsAt: start.addingTimeInterval(nextFraction * hours * 3600), title: block.1, detail: block.2)
            }
            return AIDraftResult(draftID: UUID(), kind: .agenda, agenda: agenda, questions: [])
        case .questions:
            return AIDraftResult(draftID: UUID(), kind: .questions, agenda: [], questions: [
                QuestionDraft(prompt: "How did you hear about this event?", kind: .singleChoice, options: ["Friends", "Social media", "University", "Zuno"], required: false),
                QuestionDraft(prompt: "What do you most want to learn?", kind: .longText, required: false),
                QuestionDraft(prompt: "Do you need any accessibility support?", kind: .yesNo, required: true),
            ])
        }
    }

    func resolveDraft(id: UUID, approved: Bool) async throws {}
}

// MARK: - Check-in

extension DevelopmentBackend: CheckInRepository {
    func checkIn(eventID: UUID, code: String) async throws -> CheckInOutcome {
        await latency()
        guard let organizer = ownedOrganizer(), events[eventID]?.summary.organizerID == organizer.id else {
            throw ZunoError.server(code: "not_authorized", message: nil)
        }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = normalized.uppercased().replacingOccurrences(of: "-", with: "")
        guard let index = tickets.firstIndex(where: {
            $0.ticket.qrPayload == normalized || $0.ticket.code.replacingOccurrences(of: "-", with: "") == manual
        }) else {
            return CheckInOutcome(result: .invalid)
        }
        let ticket = tickets[index].ticket
        guard ticket.event.id == eventID else { return CheckInOutcome(result: .wrongEvent, attendeeName: nil, tierName: ticket.tierName) }
        switch ticket.status {
        case .refunded: return CheckInOutcome(result: .refunded, attendeeName: ticket.attendeeName, tierName: ticket.tierName)
        case .cancelled: return CheckInOutcome(result: .cancelled, attendeeName: ticket.attendeeName, tierName: ticket.tierName)
        case .checkedIn:
            return CheckInOutcome(result: .alreadyUsed, attendeeName: ticket.attendeeName, tierName: ticket.tierName, checkedInAt: ticket.checkedInAt)
        case .valid:
            let now = clock()
            tickets[index].ticket.status = .checkedIn
            tickets[index].ticket.checkedInAt = now
            return CheckInOutcome(result: .valid, attendeeName: ticket.attendeeName, tierName: ticket.tierName, checkedInAt: now)
        }
    }
}

/// Development auth: deterministic Apple/Google/email flows that end in a "session".
actor DevelopmentAuthService: AuthService {
    private let backend: DevelopmentBackend
    private let apple: AppleAuthorizing
    private var continuations: [UUID: AsyncStream<AuthSnapshot>.Continuation] = [:]
    private var user: AuthUser?
    private var identities: [LinkedIdentity] = []
    private let keychain = Keychain(service: "lk.zuno.app.dev-session")

    init(backend: DevelopmentBackend, apple: AppleAuthorizing, startSignedIn: Bool) async {
        self.backend = backend
        self.apple = apple
        if startSignedIn || keychain.data(for: "dev-user") != nil {
            let id = backend.developmentUserID
            let restored = keychain.data(for: "dev-user").flatMap { UUID(uuidString: String(decoding: $0, as: UTF8.self)) } ?? id
            await backend.signIn(userID: restored, email: "dev.attendee@zuno.example", displayName: nil, completeProfile: true)
            user = AuthUser(id: restored, email: "dev.attendee@zuno.example", isEmailConfirmed: true, providers: ["email", "apple"], displayNameHint: "Nethmi Perera")
            identities = [
                LinkedIdentity(id: UUID().uuidString, provider: .email, email: "dev.attendee@zuno.example", linkedAt: .now.addingTimeInterval(-86_400 * 60)),
                LinkedIdentity(id: UUID().uuidString, provider: .apple, email: "dev.attendee@zuno.example", linkedAt: .now.addingTimeInterval(-86_400 * 30)),
            ]
        }
    }

    nonisolated func authEvents() -> AsyncStream<AuthSnapshot> {
        let (stream, continuation) = AsyncStream<AuthSnapshot>.makeStream()
        let id = UUID()
        Task { await self.register(continuation, id: id) }
        continuation.onTermination = { _ in Task { await self.unregister(id) } }
        return stream
    }

    private func register(_ continuation: AsyncStream<AuthSnapshot>.Continuation, id: UUID) {
        continuations[id] = continuation
        continuation.yield(AuthSnapshot(user: user, event: .initial))
    }

    private func unregister(_ id: UUID) { continuations[id] = nil }

    private func emit(_ event: AuthEvent) {
        for continuation in continuations.values { continuation.yield(AuthSnapshot(user: user, event: event)) }
    }

    private func establish(email: String?, name: String?, providers: [AuthProviderKind]) async {
        let id = UUID()
        await backend.signIn(userID: id, email: email, displayName: name, completeProfile: false)
        user = AuthUser(id: id, email: email, isEmailConfirmed: true, providers: providers.map(\.rawValue), displayNameHint: name)
        identities = providers.map { LinkedIdentity(id: UUID().uuidString, provider: $0, email: email, linkedAt: .now) }
        try? keychain.set(Data(id.uuidString.utf8), for: "dev-user")
        emit(.signedIn)
    }

    func signInWithApple(_ credential: AppleCredential) async throws {
        try await Task.sleep(for: .milliseconds(300))
        await establish(email: credential.email ?? "apple.user@privaterelay.appleid.com", name: credential.formattedName, providers: [.apple])
    }

    func signInWithGoogle() async throws {
        try await Task.sleep(for: .milliseconds(400))
        await establish(email: "google.user@zuno.example", name: "Google User", providers: [.google])
    }

    func signIn(email: String, password: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
        guard password.count >= 6, !password.lowercased().contains("wrong") else { throw AuthFlowError.invalidCredentials }
        if email.lowercased() == "dev.attendee@zuno.example" {
            let id = backend.developmentUserID
            await backend.signIn(userID: id, email: email, displayName: nil, completeProfile: true)
            user = AuthUser(id: id, email: email, isEmailConfirmed: true, providers: ["email"], displayNameHint: "Nethmi Perera")
            identities = [LinkedIdentity(id: UUID().uuidString, provider: .email, email: email, linkedAt: .now)]
            try? keychain.set(Data(id.uuidString.utf8), for: "dev-user")
            emit(.signedIn)
        } else {
            await establish(email: email, name: nil, providers: [.email])
        }
    }

    func signUp(email: String, password: String, displayName: String) async throws -> SignUpOutcome {
        try await Task.sleep(for: .milliseconds(300))
        guard PasswordPolicy.isAcceptable(password) else { throw AuthFlowError.weakPassword }
        return .confirmationRequired(email: email)
    }

    func resendConfirmation(email: String) async throws {}
    func sendPasswordReset(email: String) async throws { try await Task.sleep(for: .milliseconds(300)) }
    func updatePassword(_ newPassword: String) async throws {
        guard PasswordPolicy.isAcceptable(newPassword) else { throw AuthFlowError.weakPassword }
    }
    func handle(url: URL) async -> Bool { false }

    func signOut() async {
        await backend.signOut()
        user = nil
        identities = []
        keychain.remove("dev-user")
        emit(.signedOut)
    }

    func deleteAccount() async throws {
        await backend.deleteCurrentUser()
        await signOut()
    }

    func linkedIdentities() async throws -> [LinkedIdentity] { identities }

    func linkApple(_ credential: AppleCredential) async throws {
        guard !identities.contains(where: { $0.provider == .apple }) else { throw AuthFlowError.identityAlreadyLinked }
        identities.append(LinkedIdentity(id: UUID().uuidString, provider: .apple, email: credential.email, linkedAt: .now))
        emit(.userUpdated)
    }

    func linkGoogle() async throws {
        try await Task.sleep(for: .milliseconds(300))
        guard !identities.contains(where: { $0.provider == .google }) else { throw AuthFlowError.identityAlreadyLinked }
        identities.append(LinkedIdentity(id: UUID().uuidString, provider: .google, email: "google.user@zuno.example", linkedAt: .now))
        emit(.userUpdated)
    }

    func addEmailPassword(email: String, password: String) async throws {
        guard PasswordPolicy.isAcceptable(password) else { throw AuthFlowError.weakPassword }
        identities.append(LinkedIdentity(id: UUID().uuidString, provider: .email, email: email, linkedAt: .now))
        emit(.userUpdated)
    }

    func unlink(_ identity: LinkedIdentity) async throws {
        guard identities.count > 1 else { throw AuthFlowError.lastIdentity }
        identities.removeAll { $0.id == identity.id }
        emit(.userUpdated)
    }
}
#endif
