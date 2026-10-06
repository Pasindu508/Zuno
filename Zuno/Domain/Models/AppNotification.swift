import Foundation

enum NotificationKind: String, Codable, Sendable, Hashable, CaseIterable {
    case registrationConfirmed = "registration_confirmed"
    case paymentStatus = "payment_status"
    case ticketIssued = "ticket_issued"
    case eventReminder = "event_reminder"
    case venueChange = "venue_change"
    case scheduleChange = "schedule_change"
    case eventCancelled = "event_cancelled"
    case refundStatus = "refund_status"
    case waitlistMovement = "waitlist_movement"
    case organizerUpdate = "organizer_update"
    case general

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotificationKind(rawValue: raw) ?? .general
    }

    var symbolName: String {
        switch self {
        case .registrationConfirmed: "checkmark.seal.fill"
        case .paymentStatus: "creditcard"
        case .ticketIssued: "ticket"
        case .eventReminder: "clock"
        case .venueChange: "mappin.and.ellipse"
        case .scheduleChange: "calendar.badge.clock"
        case .eventCancelled: "xmark.octagon.fill"
        case .refundStatus: "arrow.uturn.backward.circle.fill"
        case .waitlistMovement: "hourglass"
        case .organizerUpdate: "megaphone"
        case .general: "bell"
        }
    }
}

struct AppNotification: Identifiable, Hashable, Sendable {
    var id: UUID
    var kind: NotificationKind
    var title: String
    var body: String
    var eventID: UUID?
    var readAt: Date?
    var createdAt: Date

    var isUnread: Bool { readAt == nil }
}

struct NotificationPreferences: Hashable, Sendable, Codable {
    var eventReminders = true
    var paymentUpdates = true
    var eventChanges = true
    var waitlistUpdates = true
    var organizerNews = false
    var pushEnabled = false

    private enum CodingKeys: String, CodingKey {
        case eventReminders = "event_reminders"
        case paymentUpdates = "payment_updates"
        case eventChanges = "event_changes"
        case waitlistUpdates = "waitlist_updates"
        case organizerNews = "organizer_news"
        case pushEnabled = "push_enabled"
    }
}
