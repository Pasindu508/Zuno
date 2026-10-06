import Foundation

// Repository protocols isolate features from Supabase. Live implementations live in
// `Live/`; the DEBUG-only development backend in `Development/` implements the same
// protocols for previews, simulator review and tests.

protocol EventRepository: Sendable {
    func categories() async throws -> [EventCategory]
    func searchEvents(query: String?, filters: EventFilters, limit: Int) async throws -> [EventSummary]
    func eventDetail(id: UUID) async throws -> EventDetail
    func savedEventIDs() async throws -> Set<UUID>
    func setSaved(_ saved: Bool, eventID: UUID) async throws
    func savedEvents() async throws -> [EventSummary]
    func followedOrganizerIDs() async throws -> Set<UUID>
    func setFollowing(_ following: Bool, organizerID: UUID) async throws
}

protocol RegistrationRepository: Sendable {
    func quoteFreeRegistration(eventID: UUID) async throws -> FreeRegistrationQuote
    func registerFree(eventID: UUID, answers: [RegistrationAnswer], expectedFee: Money, idempotencyKey: String) async throws -> RegistrationConfirmation
    func joinWaitlist(eventID: UUID) async throws -> WaitlistConfirmation
    func cancelRegistration(id: UUID) async throws
    func registrations() async throws -> [RegistrationRecord]
}

protocol CheckoutRepository: Sendable {
    func createCheckout(_ request: CheckoutRequest) async throws -> CheckoutSession
    func order(id: UUID) async throws -> OrderSnapshot
    #if DEBUG
    /// Development backend only: applies a simulated gateway notification through the
    /// same verification path a real PayHere callback takes on the server.
    func simulateGatewayNotification(orderID: UUID, statusCode: Int) async throws
    #endif
}

protocol WalletRepository: Sendable {
    func summary() async throws -> WalletSummary
    func transactions() async throws -> [WalletTransaction]
}

protocol TicketRepository: Sendable {
    func tickets() async throws -> [Ticket]
}

protocol ProfileRepository: Sendable {
    func currentProfile() async throws -> UserProfile?
    func saveProfile(_ draft: ProfileDraft, markOnboardingComplete: Bool) async throws -> UserProfile
    func uploadAvatar(_ jpegData: Data) async throws -> String
    func submitNationalIdentifier(_ value: String) async throws -> IdentityCheckResult
}

protocol NotificationRepository: Sendable {
    func notifications() async throws -> [AppNotification]
    func markRead(ids: [UUID]) async throws
    func markAllRead() async throws
    func preferences() async throws -> NotificationPreferences
    func updatePreferences(_ preferences: NotificationPreferences) async throws
    func registerPushToken(_ token: String, environment: String) async throws
    /// Emits when the user's notifications change on the server (Realtime).
    func changes() async -> AsyncStream<Void>
}

protocol OrganizerRepository: Sendable {
    func dashboard() async throws -> OrganizerDashboard?
    func createOrganizerProfile(_ draft: OrganizerProfileDraft) async throws -> OrganizerProfile
    func venues() async throws -> [Venue]
    func createVenue(name: String, addressLine: String, city: String) async throws -> Venue
    func saveEventDraft(_ draft: EventDraft) async throws -> EventDraft
    func eventDraft(id: UUID) async throws -> EventDraft
    func uploadEventImage(eventID: UUID, organizerID: UUID, jpegData: Data) async throws -> String
    func submitForPublish(eventID: UUID) async throws
    func stats(eventID: UUID) async throws -> OrganizerEventStats
    func attendees(eventID: UUID) async throws -> [AttendeeRow]
    func settlements() async throws -> [SettlementRow]
    func sendUpdate(eventID: UUID, kind: EventUpdateKind, message: String) async throws -> Int
    func exportAttendees(eventID: UUID) async throws -> ExportedFile
    func generateDraft(eventID: UUID, kind: AIDraftKind, instructions: String?) async throws -> AIDraftResult
    func resolveDraft(id: UUID, approved: Bool) async throws
}

protocol CheckInRepository: Sendable {
    func checkIn(eventID: UUID, code: String) async throws -> CheckInOutcome
}

/// Errors surfaced to features with user-facing copy. Server machine codes map here.
enum ZunoError: LocalizedError, Equatable, Sendable {
    case offline
    case notAuthenticated
    case notConfigured
    case server(code: String, message: String?)
    case registration(RegistrationBlockReason)
    case feeChanged
    case answersInvalid
    case paymentVerificationTimedOut
    case rateLimited
    case notFound
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .offline: String(localized: "You're offline. Check your connection and try again.")
        case .notAuthenticated: String(localized: "Please sign in to continue.")
        case .notConfigured: String(localized: "Zuno isn't connected to its server yet.")
        case .server(let code, let message): message ?? Self.serverMessage(for: code)
        case .registration(let reason): reason.message
        case .feeChanged: String(localized: "The registration fee changed. Review the new amount before confirming.")
        case .answersInvalid: String(localized: "Some required answers are missing.")
        case .paymentVerificationTimedOut: String(localized: "We haven't received payment confirmation yet. We'll update your order as soon as PayHere confirms it.")
        case .rateLimited: String(localized: "Too many attempts. Please wait a moment and try again.")
        case .notFound: String(localized: "We couldn't find that.")
        case .unknown(let message): message
        }
    }

    /// User-facing copy for server machine codes that carry no message of their own.
    static func serverMessage(for code: String) -> String {
        switch code {
        case "seats_available": String(localized: "Places are still available — register instead of joining the waitlist.")
        case "not_cancellable": String(localized: "Paid tickets can't be cancelled here. See the event's refund policy.")
        case "already_checked_in": String(localized: "You've already checked in to this event.")
        case "registration_not_found", "not_found": String(localized: "We couldn't find that registration.")
        case "invalid_phone": String(localized: "Enter a Sri Lankan mobile number, e.g. 077 123 4567.")
        case "email_required": String(localized: "Add an email address to your account to receive receipts.")
        case "order_not_pending": String(localized: "This order has already been completed or closed.")
        case "idempotency_conflict": String(localized: "That request was already sent with different details. Please start again.")
        case "already_verified": String(localized: "Your identity setup is already complete.")
        case "organizer_has_active_events": String(localized: "Cancel or finish your published events before deleting your account.")
        case "confirmation_required": String(localized: "Type DELETE to confirm.")
        case "organizer_not_verified": String(localized: "Your organizer profile is still being verified.")
        case "creation_fee_unpaid": String(localized: "Pay the event creation fee before publishing.")
        case "validation_failed": String(localized: "Some event details need attention before publishing.")
        case "not_owner", "not_authorized": String(localized: "You don't have access to this event.")
        case "invalid_format": String(localized: "That doesn't look like a Sri Lankan NIC number.")
        case "invalid_amount": String(localized: "Top-ups must be between LKR 100 and LKR 50,000.")
        default: String(localized: "Something went wrong on our side. Please try again.")
        }
    }

    /// Maps a contract machine code (RPC `P0001` message or function `error`) to a typed error.
    static func fromServerCode(_ code: String, message: String? = nil) -> ZunoError {
        if let reason = RegistrationBlockReason(rawValue: code) { return .registration(reason) }
        switch code {
        case "fee_changed": return .feeChanged
        case "answers_invalid": return .answersInvalid
        case "rate_limited": return .rateLimited
        case "not_authenticated": return .notAuthenticated
        case "event_not_found", "not_found": return .notFound
        default: return .server(code: code, message: message)
        }
    }
}
