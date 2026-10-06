import Foundation

enum RegistrationStatus: String, Codable, Sendable, Hashable {
    case confirmed, waitlisted, offered, cancelled
}

enum RegistrationKind: String, Codable, Sendable, Hashable {
    case free, paid
}

/// Why the server says a free registration cannot proceed. Codes come from the contract.
enum RegistrationBlockReason: String, Codable, Sendable, Hashable, Error {
    case alreadyRegistered = "already_registered"
    case soldOut = "sold_out"
    case registrationClosed = "registration_closed"
    case insufficientBalance = "insufficient_balance"
    case identityRequired = "identity_required"
    case notFreeEvent = "not_free_event"

    var message: String {
        switch self {
        case .alreadyRegistered: String(localized: "You're already registered for this event.")
        case .soldOut: String(localized: "This event is full. You can join the waitlist.")
        case .registrationClosed: String(localized: "Registration for this event has closed.")
        case .insufficientBalance: String(localized: "Your wallet balance is too low for this registration. Top up to continue.")
        case .identityRequired: String(localized: "Finish identity setup in your profile before registering.")
        case .notFreeEvent: String(localized: "This event needs a ticket.")
        }
    }
}

/// Server quote shown before the user confirms a free registration.
struct FreeRegistrationQuote: Hashable, Codable, Sendable {
    var allowanceLimit: Int
    var allowanceUsed: Int
    var allowanceRemaining: Int
    var fee: Money
    var walletBalance: Money
    var canRegister: Bool
    var reason: RegistrationBlockReason?
    var seatsRemaining: Int
    var month: String

    var requiresWalletDeduction: Bool { fee.minorUnits > 0 }
    var balanceAfter: Money { walletBalance - fee }
}

/// A typed answer to an organizer question.
enum AnswerValue: Hashable, Sendable, Codable {
    case text(String)
    case choices([String])
    case bool(Bool)

    var isEmpty: Bool {
        switch self {
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .choices(let values): values.isEmpty
        case .bool: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let array = try? container.decode([String].self) { self = .choices(array) }
        else { self = .text(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .choices(let values): try container.encode(values)
        case .bool(let value): try container.encode(value)
        }
    }
}

struct RegistrationAnswer: Hashable, Sendable, Codable {
    var questionID: UUID
    var value: AnswerValue

    private enum CodingKeys: String, CodingKey { case questionID = "question_id", value }
}

enum AnswerValidation {
    /// Returns the IDs of required questions that are missing a usable answer.
    static func missingRequired(questions: [RegistrationQuestion], answers: [UUID: AnswerValue]) -> [UUID] {
        questions.filter(\.required).compactMap { question in
            guard let answer = answers[question.id], !answer.isEmpty else { return question.id }
            if question.kind == .singleChoice || question.kind == .multiChoice,
               case .choices(let picked) = answer,
               !picked.allSatisfy(question.options.contains) {
                return question.id
            }
            return nil
        }
    }
}

struct RegistrationConfirmation: Hashable, Sendable, Codable {
    var registrationID: UUID
    var reference: String
    var ticketID: UUID?
    var fee: Money
    var allowanceRemaining: Int
    var walletBalance: Money
    var status: RegistrationStatus
}

struct WaitlistConfirmation: Hashable, Sendable {
    var registrationID: UUID
    var position: Int
}

struct RegistrationRecord: Identifiable, Hashable, Sendable {
    var id: UUID
    var event: TicketEventInfo
    var status: RegistrationStatus
    var kind: RegistrationKind
    var fee: Money
    var reference: String
    var createdAt: Date
}
