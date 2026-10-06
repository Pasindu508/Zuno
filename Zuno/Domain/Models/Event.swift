import Foundation

struct EventCategory: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var symbolName: String
    var sortOrder: Int

    /// Fixed client-side list so the chip row renders before the network responds.
    static let defaults: [EventCategory] = [
        .init(id: "hackathons", name: "Hackathons", symbolName: "laptopcomputer", sortOrder: 1),
        .init(id: "technology", name: "Technology", symbolName: "cpu", sortOrder: 2),
        .init(id: "workshops", name: "Workshops", symbolName: "hammer", sortOrder: 3),
        .init(id: "university", name: "University", symbolName: "graduationcap", sortOrder: 4),
        .init(id: "art", name: "Art", symbolName: "photo.artframe", sortOrder: 5),
        .init(id: "music", name: "Music", symbolName: "music.note", sortOrder: 6),
        .init(id: "sports", name: "Sports", symbolName: "figure.run", sortOrder: 7),
        .init(id: "culture", name: "Culture", symbolName: "building.columns", sortOrder: 8),
        .init(id: "careers", name: "Careers", symbolName: "briefcase", sortOrder: 9),
        .init(id: "community", name: "Community", symbolName: "person.3", sortOrder: 10),
    ]

    static func symbol(for id: String) -> String {
        defaults.first { $0.id == id }?.symbolName ?? "sparkles"
    }
}

enum EventFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case physical, online, hybrid
}

enum EventStatus: String, Codable, Sendable, Hashable {
    case draft
    case pendingReview = "pending_review"
    case published, cancelled, completed
}

struct GeoPoint: Hashable, Codable, Sendable {
    var latitude: Double
    var longitude: Double

    /// Great-circle distance in kilometres (haversine), matching the server's search filter.
    func distance(to other: GeoPoint) -> Double {
        let earthRadiusKm = 6371.0088
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = (other.latitude - latitude) * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// Where an image comes from. Storage paths are resolved to URLs by the image pipeline.
enum ImageReference: Hashable, Codable, Sendable {
    case storage(bucket: String, path: String)
    case remote(URL)
    /// Development fixture compiled into Debug builds only.
    case bundled(name: String)
}

enum Availability: Hashable, Sendable {
    case available(remaining: Int)
    case limited(remaining: Int)
    case soldOut

    static func evaluate(remaining: Int, capacity: Int) -> Availability {
        guard remaining > 0 else { return .soldOut }
        let threshold = max(5, Int((Double(capacity) * 0.1).rounded(.up)))
        return remaining <= threshold ? .limited(remaining: remaining) : .available(remaining: remaining)
    }
}

struct EventSummary: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var title: String
    var summary: String
    var categoryID: String
    var categoryName: String
    var organizerID: UUID
    var organizerName: String
    var venueName: String?
    var city: String?
    var district: String?
    var location: GeoPoint?
    var university: String?
    var format: EventFormat
    var startsAt: Date
    var endsAt: Date
    var isFree: Bool
    var minPrice: Money?
    var capacity: Int
    var seatsRemaining: Int
    var cover: ImageReference?
    var coverAlt: String?
    var tags: [String]
    var status: EventStatus

    var availability: Availability { Availability.evaluate(remaining: seatsRemaining, capacity: capacity) }

    func hasEnded(now: Date = .now) -> Bool { endsAt <= now }
    func isOngoing(now: Date = .now) -> Bool { startsAt <= now && now < endsAt }
    /// Long-running exhibitions read better as "Until …" than as a start date.
    var isMultiDay: Bool { endsAt.timeIntervalSince(startsAt) > 36 * 3600 }

    var placeLine: String {
        switch format {
        case .online: String(localized: "Online")
        case .physical, .hybrid: venueName ?? city ?? String(localized: "Venue to be announced")
        }
    }
}

struct AgendaItem: Identifiable, Hashable, Codable, Sendable {
    var id: UUID = UUID()
    var startsAt: Date
    var endsAt: Date
    var title: String
    var detail: String

    private enum CodingKeys: String, CodingKey { case startsAt = "starts_at", endsAt = "ends_at", title, detail }

    init(id: UUID = UUID(), startsAt: Date, endsAt: Date, title: String, detail: String) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.title = title
        self.detail = detail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startsAt = try c.decode(Date.self, forKey: .startsAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
    }
}

struct Speaker: Hashable, Codable, Sendable, Identifiable {
    var name: String
    var role: String
    var organization: String
    var id: String { name + role }

    init(name: String, role: String, organization: String) {
        self.name = name
        self.role = role
        self.organization = organization
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        organization = try c.decodeIfPresent(String.self, forKey: .organization) ?? ""
    }
}

struct TicketTier: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var description: String
    var price: Money
    var quantity: Int
    var remaining: Int
    var maxPerOrder: Int
    var salesStartAt: Date?
    var salesEndAt: Date?
    var onSale: Bool

    func isPurchasable(now: Date = .now) -> Bool {
        guard onSale, remaining > 0 else { return false }
        if let start = salesStartAt, now < start { return false }
        if let end = salesEndAt, now >= end { return false }
        return true
    }
}

enum QuestionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case shortText = "short_text"
    case longText = "long_text"
    case singleChoice = "single_choice"
    case multiChoice = "multi_choice"
    case yesNo = "yes_no"
}

struct RegistrationQuestion: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var prompt: String
    var kind: QuestionKind
    var options: [String]
    var required: Bool
}

struct EventMedia: Hashable, Codable, Sendable {
    var image: ImageReference
    var altText: String?
}

struct ViewerState: Hashable, Codable, Sendable {
    var isSaved: Bool
    var registrationStatus: RegistrationStatus?
    var registrationID: UUID?
    var isOrganizer: Bool

    static let anonymous = ViewerState(isSaved: false, registrationStatus: nil, registrationID: nil, isOrganizer: false)
}

struct EventDetail: Hashable, Sendable, Identifiable {
    var summary: EventSummary
    var description: String
    var addressLine: String?
    var onlineURL: URL?
    var agenda: [AgendaItem]
    var speakers: [Speaker]
    var refundPolicy: String?
    var registrationOpensAt: Date?
    var registrationClosesAt: Date?
    var organizerVerified: Bool
    var tiers: [TicketTier]
    var questions: [RegistrationQuestion]
    var gallery: [EventMedia]
    var viewer: ViewerState

    var id: UUID { summary.id }

    func isRegistrationOpen(now: Date = .now) -> Bool {
        if let opens = registrationOpensAt, now < opens { return false }
        if let closes = registrationClosesAt, now >= closes { return false }
        return now < summary.endsAt && summary.status == .published
    }
}

/// The bottom capsule action on the event detail screen.
enum EventPrimaryAction: Equatable, Sendable {
    case registerFree
    case joinOnlineEvent
    case buyTicket
    case joinWaitlist
    case onWaitlist
    case viewTicket
    case soldOut
    case registrationClosed
    case eventEnded
    case eventCancelled

    var title: String {
        switch self {
        case .registerFree: String(localized: "Register free")
        case .joinOnlineEvent: String(localized: "Join event")
        case .buyTicket: String(localized: "Buy ticket")
        case .joinWaitlist: String(localized: "Join waitlist")
        case .onWaitlist: String(localized: "You're on the waitlist")
        case .viewTicket: String(localized: "View ticket")
        case .soldOut: String(localized: "Sold out")
        case .registrationClosed: String(localized: "Registration closed")
        case .eventEnded: String(localized: "Event ended")
        case .eventCancelled: String(localized: "Event cancelled")
        }
    }

    var isEnabled: Bool {
        switch self {
        case .registerFree, .joinOnlineEvent, .buyTicket, .joinWaitlist, .viewTicket: true
        case .onWaitlist, .soldOut, .registrationClosed, .eventEnded, .eventCancelled: false
        }
    }

    static func resolve(for detail: EventDetail, now: Date = .now) -> EventPrimaryAction {
        let event = detail.summary
        if event.status == .cancelled { return .eventCancelled }
        if event.hasEnded(now: now) { return .eventEnded }
        switch detail.viewer.registrationStatus {
        case .confirmed?: return .viewTicket
        case .waitlisted?: return .onWaitlist
        case .offered?: return event.isFree ? .registerFree : .buyTicket
        case .cancelled?, nil: break
        }
        guard detail.isRegistrationOpen(now: now) else { return .registrationClosed }
        if event.isFree {
            if event.seatsRemaining <= 0 { return .joinWaitlist }
            return event.format == .online ? .joinOnlineEvent : .registerFree
        }
        let purchasable = detail.tiers.contains { $0.isPurchasable(now: now) }
        if purchasable { return .buyTicket }
        // Waitlists exist for full free events only (the server rejects paid waitlists).
        let soldOut = !detail.tiers.isEmpty && detail.tiers.allSatisfy { $0.remaining <= 0 }
        return soldOut ? .soldOut : .registrationClosed
    }
}
