import Foundation

enum OrganizerVerification: String, Codable, Sendable, Hashable {
    case pending, verified, rejected, suspended

    var label: String {
        switch self {
        case .pending: String(localized: "Verification pending")
        case .verified: String(localized: "Verified organizer")
        case .rejected: String(localized: "Verification declined")
        case .suspended: String(localized: "Suspended")
        }
    }
}

struct OrganizerProfile: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var slug: String
    var bio: String
    var logoPath: String?
    var contactEmail: String
    var verification: OrganizerVerification
}

struct OrganizerProfileDraft: Hashable, Sendable {
    var name = ""
    var bio = ""
    var contactEmail = ""

    var slug: String {
        let allowed = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(allowed).split(separator: "-").joined(separator: "-")
    }

    var isValid: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 3 && contactEmail.contains("@") && bio.count >= 20
    }
}

struct SalesTotals: Hashable, Sendable {
    var gross: Money
    var commission: Money
    var net: Money
    static let zero = SalesTotals(gross: .zero, commission: .zero, net: .zero)
}

struct OrganizerEventRow: Identifiable, Hashable, Sendable {
    var event: EventSummary
    var registrations: Int
    var checkedIn: Int
    var id: UUID { event.id }
}

struct OrganizerDashboard: Hashable, Sendable {
    var organizer: OrganizerProfile
    var events: [OrganizerEventRow]
    var totals: SalesTotals
}

struct TierSales: Hashable, Sendable, Identifiable {
    var tierID: UUID
    var name: String
    var sold: Int
    var quantity: Int
    var gross: Money
    var id: UUID { tierID }
}

struct OrganizerEventStats: Hashable, Sendable {
    var capacity: Int
    var registrations: Int
    var waitlisted: Int
    var checkedIn: Int
    var ticketsSold: Int
    var gross: Money
    var commission: Money
    var net: Money
    var byTier: [TierSales]

    var checkInProgress: Double {
        let base = max(registrations, 1)
        return min(Double(checkedIn) / Double(base), 1)
    }
}

struct AttendeeRow: Identifiable, Hashable, Sendable {
    var ticketID: UUID
    var attendeeName: String
    var tierName: String
    var status: TicketStatus
    var checkedInAt: Date?
    var registrationReference: String
    var id: UUID { ticketID }
}

enum PayoutStatus: String, Sendable, Hashable, Codable {
    case unsettled, scheduled, paid
    var label: String {
        switch self {
        case .unsettled: String(localized: "Unsettled")
        case .scheduled: String(localized: "Payout scheduled")
        case .paid: String(localized: "Paid out")
        }
    }
}

struct SettlementRow: Identifiable, Hashable, Sendable {
    var eventID: UUID
    var title: String
    var gross: Money
    var commission: Money
    var net: Money
    var payoutStatus: PayoutStatus
    var id: UUID { eventID }
}

struct Venue: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var addressLine: String
    var city: String
    var district: String
    var location: GeoPoint?
}

struct TierDraft: Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var description = ""
    var price: Money = .rupees(1_000)
    var quantity = 100
    var maxPerOrder = 4
    var salesStartAt: Date?
    var salesEndAt: Date?
}

struct QuestionDraft: Identifiable, Hashable, Sendable, Codable {
    var id = UUID()
    var prompt = ""
    var kind: QuestionKind = .shortText
    var options: [String] = []
    var required = false

    private enum CodingKeys: String, CodingKey { case prompt, kind, options, required }

    init(id: UUID = UUID(), prompt: String = "", kind: QuestionKind = .shortText, options: [String] = [], required: Bool = false) {
        self.id = id
        self.prompt = prompt
        self.kind = kind
        self.options = options
        self.required = required
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        kind = try c.decode(QuestionKind.self, forKey: .kind)
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
    }
}

struct EventDraft: Identifiable, Hashable, Sendable {
    var id: UUID
    var organizerID: UUID
    var title = ""
    var summary = ""
    var description = ""
    var categoryID = "technology"
    var format: EventFormat = .physical
    var venueID: UUID?
    var onlineURL = ""
    var startsAt: Date
    var endsAt: Date
    var capacity = 100
    var isFree = true
    var university = ""
    var tags: [String] = []
    var coverPath: String?
    var coverAlt = ""
    var agenda: [AgendaItem] = []
    var speakers: [Speaker] = []
    var refundPolicy = ""
    var registrationClosesAt: Date?
    var tiers: [TierDraft] = []
    var questions: [QuestionDraft] = []
    var status: EventStatus = .draft
    var creationFeePaid = false

    init(id: UUID = UUID(), organizerID: UUID, now: Date = .now) {
        self.id = id
        self.organizerID = organizerID
        let start = Calendar.colombo.date(byAdding: .day, value: 14, to: Calendar.colombo.startOfDay(for: now))!
            .addingTimeInterval(18 * 3600)
        startsAt = start
        endsAt = start.addingTimeInterval(3 * 3600)
    }

    enum Issue: String, CaseIterable, Sendable, Hashable {
        case title, summary, description, schedule, startInPast, capacity, venue, cover, tiers
        var message: String {
            switch self {
            case .title: String(localized: "Add a title of at least 4 characters.")
            case .summary: String(localized: "Add a one-line summary of at least 20 characters.")
            case .description: String(localized: "Describe the event in at least 40 characters.")
            case .schedule: String(localized: "The end time must be after the start time.")
            case .startInPast: String(localized: "The event must start in the future.")
            case .capacity: String(localized: "Capacity must be at least 1.")
            case .venue: String(localized: "Choose a venue, or add an online link for online events.")
            case .cover: String(localized: "Upload a cover image.")
            case .tiers: String(localized: "Paid events need at least one ticket tier with a price.")
            }
        }
    }

    /// Mirrors the server's publish validation so organizers see problems early.
    func validationIssues(now: Date = .now) -> [Issue] {
        var issues: [Issue] = []
        if title.trimmingCharacters(in: .whitespaces).count < 4 { issues.append(.title) }
        if summary.trimmingCharacters(in: .whitespaces).count < 20 { issues.append(.summary) }
        if description.trimmingCharacters(in: .whitespaces).count < 40 { issues.append(.description) }
        if endsAt <= startsAt { issues.append(.schedule) }
        if startsAt <= now { issues.append(.startInPast) }
        if capacity < 1 { issues.append(.capacity) }
        switch format {
        case .physical: if venueID == nil { issues.append(.venue) }
        case .online: if URL(string: onlineURL)?.scheme?.hasPrefix("http") != true { issues.append(.venue) }
        case .hybrid:
            if venueID == nil || URL(string: onlineURL)?.scheme?.hasPrefix("http") != true { issues.append(.venue) }
        }
        if coverPath == nil { issues.append(.cover) }
        if !isFree && (tiers.isEmpty || tiers.contains { $0.price.minorUnits <= 0 || $0.quantity < 1 }) {
            issues.append(.tiers)
        }
        return issues
    }
}

enum AIDraftKind: String, Codable, Sendable, Hashable {
    case agenda, questions
}

struct AIDraftResult: Hashable, Sendable {
    var draftID: UUID
    var kind: AIDraftKind
    var agenda: [AgendaItem]
    var questions: [QuestionDraft]
}

struct ExportedFile: Hashable, Sendable {
    var filename: String
    var contents: String
}

enum EventUpdateKind: String, CaseIterable, Identifiable, Sendable {
    case general
    case venueChange = "venue_change"
    case scheduleChange = "schedule_change"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: String(localized: "General update")
        case .venueChange: String(localized: "Venue change")
        case .scheduleChange: String(localized: "Schedule change")
        }
    }
}
