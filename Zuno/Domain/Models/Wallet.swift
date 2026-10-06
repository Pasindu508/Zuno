import Foundation

struct WalletSummary: Hashable, Sendable {
    var balance: Money
    var allowanceLimit: Int
    var allowanceUsed: Int
    var allowanceRemaining: Int
    var extraFee: Money
    var month: String
    var pendingTopUps: Money

    var isLowBalance: Bool { balance < extraFee * 2 }
}

enum WalletEntryType: String, Codable, Sendable, Hashable {
    case topup
    case freeRegistrationFee = "free_registration_fee"
    case refundCredit = "refund_credit"
    case ticketPurchase = "ticket_purchase"
    case adjustment

    var title: String {
        switch self {
        case .topup: String(localized: "Wallet top-up")
        case .freeRegistrationFee: String(localized: "Free registration fee")
        case .refundCredit: String(localized: "Refund credit")
        case .ticketPurchase: String(localized: "Ticket purchase")
        case .adjustment: String(localized: "Adjustment")
        }
    }

    var symbolName: String {
        switch self {
        case .topup: "arrow.down.circle"
        case .freeRegistrationFee: "ticket"
        case .refundCredit: "arrow.uturn.backward.circle.fill"
        case .ticketPurchase: "creditcard"
        case .adjustment: "slider.horizontal.3"
        }
    }
}

enum LedgerStatus: String, Codable, Sendable, Hashable {
    case pending, posted, failed

    var label: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .posted: String(localized: "Completed")
        case .failed: String(localized: "Failed")
        }
    }
}

struct WalletTransaction: Identifiable, Hashable, Sendable {
    var id: UUID
    var type: WalletEntryType
    /// Signed: credits positive, debits negative.
    var amount: Money
    var balanceAfter: Money?
    var status: LedgerStatus
    var description: String
    var referenceType: String?
    var referenceID: UUID?
    var createdAt: Date
}

enum WalletTopUpPolicy {
    static let minimum = Money.rupees(100)
    static let maximum = Money.rupees(50_000)
    static let presets: [Money] = [.rupees(500), .rupees(1_000), .rupees(2_000), .rupees(5_000)]

    static func validate(_ amount: Money) -> Bool { amount >= minimum && amount <= maximum }
}
