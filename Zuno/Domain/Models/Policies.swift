import Foundation

extension TimeZone {
    /// Sri Lanka Standard Time (UTC+05:30, no daylight saving).
    static let colombo = TimeZone(identifier: "Asia/Colombo")!
}

extension Calendar {
    /// Gregorian calendar in Asia/Colombo, used for every business-date calculation.
    static let colombo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .colombo
        calendar.firstWeekday = 2 // Monday
        calendar.locale = Locale(identifier: "en_LK")
        return calendar
    }()
}

/// The free-event allowance rule. The server is authoritative; this mirrors it so the
/// client can explain the exact deduction before the user confirms, and so the
/// development backend and unit tests use one definition.
struct FreeRegistrationPolicy: Sendable, Hashable {
    static let allowedFeeRange: ClosedRange<Int64> = 250...300 // LKR 2.50 – 3.00

    var monthlyAllowance: Int
    var extraFee: Money

    init(monthlyAllowance: Int = 15, extraFee: Money = .lkr(250)) {
        precondition(Self.allowedFeeRange.contains(extraFee.minorUnits), "Extra fee must be LKR 2.50–3.00")
        self.monthlyAllowance = monthlyAllowance
        self.extraFee = extraFee
    }

    func remaining(usedThisMonth used: Int) -> Int { max(monthlyAllowance - used, 0) }

    func fee(usedThisMonth used: Int) -> Money { used < monthlyAllowance ? .zero : extraFee }

    struct Evaluation: Equatable, Sendable {
        var canRegister: Bool
        var reason: RegistrationBlockReason?
        var fee: Money
    }

    /// Evaluates in the same order as `register_for_free_event` on the server.
    func evaluate(
        isFreeEvent: Bool,
        registrationOpen: Bool,
        alreadyRegistered: Bool,
        seatsRemaining: Int,
        identityVerified: Bool,
        usedThisMonth: Int,
        walletBalance: Money
    ) -> Evaluation {
        let fee = fee(usedThisMonth: usedThisMonth)
        func blocked(_ reason: RegistrationBlockReason) -> Evaluation { Evaluation(canRegister: false, reason: reason, fee: fee) }
        guard isFreeEvent else { return blocked(.notFreeEvent) }
        guard registrationOpen else { return blocked(.registrationClosed) }
        guard !alreadyRegistered else { return blocked(.alreadyRegistered) }
        guard seatsRemaining > 0 else { return blocked(.soldOut) }
        guard identityVerified else { return blocked(.identityRequired) }
        guard walletBalance >= fee else { return blocked(.insufficientBalance) }
        return Evaluation(canRegister: true, reason: nil, fee: fee)
    }

    /// Allowance month key in Asia/Colombo, e.g. "2026-10".
    static func monthKey(for date: Date) -> String {
        let parts = Calendar.colombo.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// Generates idempotency keys for server mutations. One key per user intent: retries of
/// the same intent reuse it, so a duplicate tap or network retry cannot double-charge.
enum IdempotencyKey {
    static func make(prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.lowercased())"
    }
}
