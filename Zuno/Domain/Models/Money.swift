import Foundation

/// Exact money in integer minor units (LKR cents). Never use floating point for money.
struct Money: Hashable, Codable, Sendable, Comparable {
    var minorUnits: Int64
    var currency: String

    init(minorUnits: Int64, currency: String = "LKR") {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    static func lkr(_ minorUnits: Int64) -> Money { Money(minorUnits: minorUnits, currency: "LKR") }
    /// Convenience for whole rupees, e.g. `.rupees(1_500)` == LKR 1,500.00.
    static func rupees(_ rupees: Int64) -> Money { .lkr(rupees * 100) }
    static let zero = Money.lkr(0)

    var isZero: Bool { minorUnits == 0 }
    var isNegative: Bool { minorUnits < 0 }
    var magnitude: Money { Money(minorUnits: abs(minorUnits), currency: currency) }

    static func < (lhs: Money, rhs: Money) -> Bool { lhs.minorUnits < rhs.minorUnits }
    static func + (lhs: Money, rhs: Money) -> Money { Money(minorUnits: lhs.minorUnits + rhs.minorUnits, currency: lhs.currency) }
    static func - (lhs: Money, rhs: Money) -> Money { Money(minorUnits: lhs.minorUnits - rhs.minorUnits, currency: lhs.currency) }
    static func * (lhs: Money, rhs: Int) -> Money { Money(minorUnits: lhs.minorUnits * Int64(rhs), currency: lhs.currency) }
    static prefix func - (value: Money) -> Money { Money(minorUnits: -value.minorUnits, currency: value.currency) }

    /// Decimal amount for display and PayHere field formatting.
    var decimalAmount: Decimal { Decimal(minorUnits) / 100 }
}
