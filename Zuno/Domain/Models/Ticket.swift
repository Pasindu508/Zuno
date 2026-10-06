import Foundation

enum TicketStatus: String, Codable, Sendable, Hashable {
    case valid
    case checkedIn = "checked_in"
    case cancelled
    case refunded

    var label: String {
        switch self {
        case .valid: String(localized: "Valid")
        case .checkedIn: String(localized: "Checked in")
        case .cancelled: String(localized: "Cancelled")
        case .refunded: String(localized: "Refunded")
        }
    }
}

struct TicketEventInfo: Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var startsAt: Date
    var endsAt: Date
    var venueName: String?
    var city: String?
    var cover: ImageReference?
    var coverAlt: String?
    var status: EventStatus
    var categoryID: String
}

struct Ticket: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var code: String
    var qrPayload: String
    var status: TicketStatus
    var tierName: String
    var attendeeName: String
    var issuedAt: Date
    var checkedInAt: Date?
    var registrationReference: String
    var orderID: UUID?
    var event: TicketEventInfo
}

enum TicketSegment: String, CaseIterable, Identifiable, Sendable {
    case upcoming, past, cancelled
    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcoming: String(localized: "Upcoming")
        case .past: String(localized: "Past")
        case .cancelled: String(localized: "Cancelled")
        }
    }

    static func segment(for ticket: Ticket, now: Date = .now) -> TicketSegment {
        if ticket.status == .cancelled || ticket.status == .refunded || ticket.event.status == .cancelled {
            return .cancelled
        }
        return ticket.event.endsAt < now ? .past : .upcoming
    }

    static func group(_ tickets: [Ticket], now: Date = .now) -> [TicketSegment: [Ticket]] {
        var groups: [TicketSegment: [Ticket]] = [:]
        for ticket in tickets {
            groups[segment(for: ticket, now: now), default: []].append(ticket)
        }
        groups[.upcoming]?.sort { $0.event.startsAt < $1.event.startsAt }
        groups[.past]?.sort { $0.event.startsAt > $1.event.startsAt }
        groups[.cancelled]?.sort { $0.event.startsAt > $1.event.startsAt }
        return groups
    }
}
