import Foundation

enum OrderKind: String, Codable, Sendable, Hashable {
    case ticket
    case walletTopUp = "wallet_topup"
    case eventCreationFee = "event_creation_fee"
}

enum OrderStatus: String, Codable, Sendable, Hashable {
    case pending, paid, failed, cancelled, expired, refunded

    var isTerminal: Bool { self != .pending }
}

struct CheckoutItem: Hashable, Sendable, Codable {
    var tierID: UUID
    var quantity: Int

    private enum CodingKeys: String, CodingKey { case tierID = "tier_id", quantity }
}

enum CheckoutPurpose: Hashable, Sendable {
    case tickets(eventID: UUID, items: [CheckoutItem], answers: [RegistrationAnswer])
    case walletTopUp(amount: Money)
    case eventCreationFee(eventID: UUID)
}

struct CheckoutRequest: Hashable, Sendable {
    var purpose: CheckoutPurpose
    var phone: String
    var idempotencyKey: String
}

struct OrderLine: Hashable, Sendable, Identifiable {
    var label: String
    var quantity: Int
    var unitPrice: Money
    var amount: Money
    var id: String { label + "\(quantity)" }
}

struct OrderSummary: Hashable, Sendable {
    var lines: [OrderLine]
    var subtotal: Money
    var commission: Money
    var total: Money
}

/// How to launch payment for an order.
enum PaymentLaunch: Hashable, Sendable {
    /// PayHere hosted checkout: a signed form POST built by the server.
    case payHere(actionURL: URL, fields: [String: String], returnURL: String, cancelURL: String)
    #if DEBUG
    /// Development backend only: a clearly labelled simulator that drives the same
    /// server-side verification path the PayHere notification would.
    case developmentSimulator
    #endif
}

struct CheckoutSession: Hashable, Sendable, Identifiable {
    var orderID: UUID
    var expiresAt: Date
    var summary: OrderSummary
    var payment: PaymentLaunch
    var id: UUID { orderID }
}

struct OrderSnapshot: Hashable, Sendable {
    var id: UUID
    var kind: OrderKind
    var status: OrderStatus
    var total: Money
    var eventID: UUID?
    var paidAt: Date?
    var createdAt: Date
}

/// Client-side pricing used for the order preview. The server recomputes everything
/// from database prices; this only mirrors the published formula for display and tests.
enum OrderPricing {
    struct Line: Hashable, Sendable {
        var tier: TicketTier
        var quantity: Int
    }

    enum PricingError: Error, Equatable {
        case emptyOrder
        case quantityExceedsLimit(tierID: UUID)
        case insufficientInventory(tierID: UUID)
        case notOnSale(tierID: UUID)
        case mixedCurrency
    }

    static func summarize(_ lines: [Line], commissionBps: Int, now: Date = .now) throws -> OrderSummary {
        let active = lines.filter { $0.quantity > 0 }
        guard !active.isEmpty else { throw PricingError.emptyOrder }
        let currency = active[0].tier.price.currency
        var subtotal: Int64 = 0
        var orderLines: [OrderLine] = []
        for line in active {
            guard line.tier.price.currency == currency else { throw PricingError.mixedCurrency }
            // Inventory first, so a sold-out tier reports "sold out" rather than "not on sale".
            guard line.quantity <= line.tier.remaining else { throw PricingError.insufficientInventory(tierID: line.tier.id) }
            guard line.tier.isPurchasable(now: now) else { throw PricingError.notOnSale(tierID: line.tier.id) }
            guard line.quantity <= line.tier.maxPerOrder else { throw PricingError.quantityExceedsLimit(tierID: line.tier.id) }
            let amount = line.tier.price.minorUnits * Int64(line.quantity)
            subtotal += amount
            orderLines.append(OrderLine(label: line.tier.name, quantity: line.quantity, unitPrice: line.tier.price,
                                        amount: Money(minorUnits: amount, currency: currency)))
        }
        let commission = CommissionPolicy.commission(onSubtotal: subtotal, basisPoints: commissionBps)
        return OrderSummary(
            lines: orderLines,
            subtotal: Money(minorUnits: subtotal, currency: currency),
            commission: Money(minorUnits: commission, currency: currency),
            total: Money(minorUnits: subtotal, currency: currency)
        )
    }
}

/// Platform commission, deducted from the organizer settlement (attendees pay face value).
enum CommissionPolicy {
    static let defaultBasisPoints = 500

    /// Half-up integer rounding: (subtotal × bps + 5000) / 10000 — identical to the SQL.
    static func commission(onSubtotal subtotal: Int64, basisPoints: Int) -> Int64 {
        precondition(subtotal >= 0 && basisPoints >= 0)
        return (subtotal * Int64(basisPoints) + 5_000) / 10_000
    }

    static func organizerNet(subtotal: Int64, basisPoints: Int) -> Int64 {
        subtotal - commission(onSubtotal: subtotal, basisPoints: basisPoints)
    }
}
