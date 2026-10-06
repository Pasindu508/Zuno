import XCTest
@testable import Zuno

final class FreeRegistrationPolicyTests: XCTestCase {
    let policy = FreeRegistrationPolicy(monthlyAllowance: 15, extraFee: .lkr(250))

    func testAllowanceRemainingAndFeeBoundary() {
        XCTAssertEqual(policy.remaining(usedThisMonth: 0), 15)
        XCTAssertEqual(policy.remaining(usedThisMonth: 14), 1)
        XCTAssertEqual(policy.remaining(usedThisMonth: 15), 0)
        XCTAssertEqual(policy.remaining(usedThisMonth: 40), 0)
        XCTAssertEqual(policy.fee(usedThisMonth: 14), .zero, "the 15th registration is still free")
        XCTAssertEqual(policy.fee(usedThisMonth: 15), .lkr(250), "the 16th costs LKR 2.50")
        XCTAssertEqual(policy.fee(usedThisMonth: 30), .lkr(250))
    }

    func testFeeMustStayWithinPublishedRange() {
        XCTAssertTrue(FreeRegistrationPolicy.allowedFeeRange.contains(250))
        XCTAssertTrue(FreeRegistrationPolicy.allowedFeeRange.contains(300))
        XCTAssertFalse(FreeRegistrationPolicy.allowedFeeRange.contains(301))
        XCTAssertFalse(FreeRegistrationPolicy.allowedFeeRange.contains(249))
    }

    func testEvaluationOrderMatchesServer() {
        func evaluate(free: Bool = true, open: Bool = true, registered: Bool = false, seats: Int = 10,
                      identity: Bool = true, used: Int = 0, balance: Int64 = 0) -> FreeRegistrationPolicy.Evaluation {
            policy.evaluate(isFreeEvent: free, registrationOpen: open, alreadyRegistered: registered, seatsRemaining: seats,
                            identityVerified: identity, usedThisMonth: used, walletBalance: .lkr(balance))
        }
        XCTAssertEqual(evaluate(free: false).reason, .notFreeEvent)
        XCTAssertEqual(evaluate(open: false).reason, .registrationClosed)
        XCTAssertEqual(evaluate(registered: true).reason, .alreadyRegistered)
        XCTAssertEqual(evaluate(seats: 0).reason, .soldOut)
        XCTAssertEqual(evaluate(identity: false).reason, .identityRequired)
        XCTAssertEqual(evaluate(used: 15, balance: 249).reason, .insufficientBalance)
        let paidFromWallet = evaluate(used: 15, balance: 250)
        XCTAssertTrue(paidFromWallet.canRegister)
        XCTAssertEqual(paidFromWallet.fee, .lkr(250))
        let free = evaluate(used: 3, balance: 0)
        XCTAssertTrue(free.canRegister)
        XCTAssertEqual(free.fee, .zero)
    }

    func testMonthKeyUsesColomboTime() throws {
        // 2026-10-31 19:00 UTC is already 1 November 00:30 in Colombo.
        let date = try Date("2026-10-31T19:00:00Z", strategy: .iso8601)
        XCTAssertEqual(FreeRegistrationPolicy.monthKey(for: date), "2026-11")
        let before = try Date("2026-10-31T18:00:00Z", strategy: .iso8601)
        XCTAssertEqual(FreeRegistrationPolicy.monthKey(for: before), "2026-10")
    }
}

final class CommissionAndPricingTests: XCTestCase {
    func testCommissionRoundsHalfUpLikeSQL() {
        XCTAssertEqual(CommissionPolicy.commission(onSubtotal: 150_000, basisPoints: 500), 7_500)
        XCTAssertEqual(CommissionPolicy.commission(onSubtotal: 10, basisPoints: 500), 1, "0.5 rounds up")
        XCTAssertEqual(CommissionPolicy.commission(onSubtotal: 9, basisPoints: 500), 0, "0.45 rounds down")
        XCTAssertEqual(CommissionPolicy.commission(onSubtotal: 199, basisPoints: 500), 10)
        XCTAssertEqual(CommissionPolicy.commission(onSubtotal: 0, basisPoints: 500), 0)
        XCTAssertEqual(CommissionPolicy.organizerNet(subtotal: 300_000, basisPoints: 500), 285_000)
    }

    private func tier(price: Int64 = 150_000, quantity: Int = 10, remaining: Int = 5, max: Int = 4, onSale: Bool = true) -> TicketTier {
        TicketTier(id: UUID(), name: "Standard", description: "", price: .lkr(price), quantity: quantity, remaining: remaining,
                   maxPerOrder: max, salesStartAt: nil, salesEndAt: nil, onSale: onSale)
    }

    func testOrderSummaryTotalsAndCommission() throws {
        let a = tier(price: 150_000), b = tier(price: 250_000)
        let summary = try OrderPricing.summarize([.init(tier: a, quantity: 2), .init(tier: b, quantity: 1)], commissionBps: 500)
        XCTAssertEqual(summary.subtotal, .lkr(550_000))
        XCTAssertEqual(summary.total, .lkr(550_000), "attendees pay face value")
        XCTAssertEqual(summary.commission, .lkr(27_500))
        XCTAssertEqual(summary.lines.count, 2)
    }

    func testInventoryAndLimitsAreEnforced() {
        let limited = tier(remaining: 2, max: 4)
        XCTAssertThrowsError(try OrderPricing.summarize([.init(tier: limited, quantity: 3)], commissionBps: 500)) { error in
            XCTAssertEqual(error as? OrderPricing.PricingError, .insufficientInventory(tierID: limited.id))
        }
        let capped = tier(remaining: 50, max: 2)
        XCTAssertThrowsError(try OrderPricing.summarize([.init(tier: capped, quantity: 3)], commissionBps: 500)) { error in
            XCTAssertEqual(error as? OrderPricing.PricingError, .quantityExceedsLimit(tierID: capped.id))
        }
        let offSale = tier(onSale: false)
        XCTAssertThrowsError(try OrderPricing.summarize([.init(tier: offSale, quantity: 1)], commissionBps: 500))
        XCTAssertThrowsError(try OrderPricing.summarize([], commissionBps: 500))
    }

    func testTopUpBounds() {
        XCTAssertFalse(WalletTopUpPolicy.validate(.rupees(99)))
        XCTAssertTrue(WalletTopUpPolicy.validate(.rupees(100)))
        XCTAssertTrue(WalletTopUpPolicy.validate(.rupees(50_000)))
        XCTAssertFalse(WalletTopUpPolicy.validate(.rupees(50_001)))
    }
}

final class FormattingTests: XCTestCase {
    func testLKRFormatting() {
        XCTAssertEqual(ZunoFormat.currency(.lkr(150_000)), "LKR 1,500.00")
        XCTAssertEqual(ZunoFormat.currency(.lkr(150_000), compact: true), "LKR 1,500")
        XCTAssertEqual(ZunoFormat.currency(.lkr(250)), "LKR 2.50")
        XCTAssertEqual(ZunoFormat.currency(.lkr(250), compact: true), "LKR 2.50", "cents are never dropped")
        XCTAssertEqual(ZunoFormat.currency(.lkr(-250)), "\u{2212}LKR 2.50")
        XCTAssertEqual(ZunoFormat.currency(.lkr(10_000), showSign: true), "+LKR 100.00")
        XCTAssertEqual(ZunoFormat.currency(.lkr(123_456_789)), "LKR 1,234,567.89")
        XCTAssertEqual(ZunoFormat.currency(.zero), "LKR 0.00")
    }

    func testGatewayAmountHasNoGrouping() {
        XCTAssertEqual(ZunoFormat.gatewayAmount(.lkr(150_000)), "1500.00")
        XCTAssertEqual(ZunoFormat.gatewayAmount(.lkr(5)), "0.05")
    }

    func testDatesUseColomboTimeZone() throws {
        // 12:30 UTC is 18:00 in Colombo.
        let start = try Date("2026-10-17T12:30:00Z", strategy: .iso8601)
        let end = start.addingTimeInterval(3 * 3600)
        let line = ZunoFormat.eventDateLine(start: start, end: end, now: start)
        XCTAssertTrue(line.contains("17 Oct"), line)
        XCTAssertTrue(line.contains("6:00") || line.contains("18:00"), line)
        let multi = ZunoFormat.eventDateLine(start: start, end: start.addingTimeInterval(20 * 86_400), now: start)
        XCTAssertTrue(multi.contains("–"), multi)
    }

    func testPillTextForOngoingExhibition() throws {
        let now = try Date("2026-10-06T06:00:00Z", strategy: .iso8601)
        var event = EventFixtures.event(start: now.addingTimeInterval(-2 * 86_400), end: now.addingTimeInterval(31 * 86_400))
        XCTAssertTrue(ZunoFormat.pillText(for: event, now: now).hasPrefix("Until"))
        event.status = .cancelled
        XCTAssertEqual(ZunoFormat.pillText(for: event, now: now), "Cancelled")
    }

    func testServerDateParsing() {
        XCTAssertNotNil(ServerDate.parse("2026-10-12T18:30:00+05:30"))
        XCTAssertNotNil(ServerDate.parse("2026-10-12T13:00:00.123456+00:00"))
        XCTAssertNotNil(ServerDate.parse("2026-10-12 13:00:00+00"))
        XCTAssertNotNil(ServerDate.parse("2026-10-12T13:00:00Z"))
        XCTAssertEqual(ServerDate.parse("2026-10-12T18:30:00+05:30"), ServerDate.parse("2026-10-12T13:00:00Z"))
        XCTAssertNil(ServerDate.parse("not a date"))
    }

    func testSriLankanMobileNormalisation() {
        XCTAssertEqual(SriLankaLocations.normalizedMobile("077 123 4567"), "+94771234567")
        XCTAssertEqual(SriLankaLocations.normalizedMobile("+94 71 234 5678"), "+94712345678")
        XCTAssertNil(SriLankaLocations.normalizedMobile("011 234 5678"), "landlines are rejected")
        XCTAssertNil(SriLankaLocations.normalizedMobile("12345"))
    }
}

final class NICInputTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(NICInput.format(of: "200012345678"), .new)
        XCTAssertEqual(NICInput.format(of: "851234567v"), .old)
        XCTAssertEqual(NICInput.format(of: "85 123 4567 X"), .old)
        XCTAssertNil(NICInput.format(of: "85123456"))
        XCTAssertNil(NICInput.format(of: "8512345678"))
        XCTAssertNil(NICInput.format(of: "ABCDEFGHIJKL"))
    }

    func testNormalisationOnlyStripsSeparators() {
        XCTAssertEqual(NICInput.normalizeForTransmission(" 851-234-567v "), "851234567V")
        XCTAssertEqual(NICInput.normalizeForTransmission("2000 1234 5678"), "200012345678")
    }
}

final class AnswerValidationTests: XCTestCase {
    func testRequiredAndChoiceValidation() {
        let required = RegistrationQuestion(id: UUID(), prompt: "Skill", kind: .singleChoice, options: ["A", "B"], required: true)
        let optional = RegistrationQuestion(id: UUID(), prompt: "Team", kind: .shortText, options: [], required: false)
        let yesNo = RegistrationQuestion(id: UUID(), prompt: "Stay?", kind: .yesNo, options: [], required: true)
        let questions = [required, optional, yesNo]
        XCTAssertEqual(Set(AnswerValidation.missingRequired(questions: questions, answers: [:])), [required.id, yesNo.id])
        XCTAssertEqual(AnswerValidation.missingRequired(questions: questions, answers: [required.id: .choices(["C"]), yesNo.id: .bool(false)]),
                       [required.id], "an option that isn't offered doesn't count")
        XCTAssertTrue(AnswerValidation.missingRequired(questions: questions, answers: [required.id: .choices(["A"]), yesNo.id: .bool(false)]).isEmpty)
    }

    func testAnswerJSONShapeMatchesContract() throws {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let data = try JSONEncoder().encode([RegistrationAnswer(questionID: id, value: .choices(["Data"])),
                                              RegistrationAnswer(questionID: id, value: .bool(true)),
                                              RegistrationAnswer(questionID: id, value: .text("Team Lotus"))])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"question_id\""))
        XCTAssertTrue(json.contains("[\"Data\"]"))
        XCTAssertTrue(json.contains("true"))
        XCTAssertTrue(json.contains("\"Team Lotus\""))
    }
}

enum EventFixtures {
    static func event(
        id: UUID = UUID(), title: String = "Northern Tech Meetup", category: String = "technology", city: String? = "Colombo",
        start: Date, end: Date, isFree: Bool = true, capacity: Int = 100, remaining: Int = 50, format: EventFormat = .physical,
        organizer: UUID = UUID(), university: String? = nil, location: GeoPoint? = GeoPoint(latitude: 6.9271, longitude: 79.8612)
    ) -> EventSummary {
        EventSummary(id: id, title: title, summary: "Cloud, data and startups", categoryID: category, categoryName: category.capitalized,
                     organizerID: organizer, organizerName: "Lanka Open Source Circle", venueName: "Innovation Hall", city: city,
                     district: city, location: location, university: university, format: format, startsAt: start, endsAt: end,
                     isFree: isFree, minPrice: isFree ? nil : .lkr(150_000), capacity: capacity, seatsRemaining: remaining,
                     cover: nil, coverAlt: nil, tags: ["cloud", "data"], status: .published)
    }
}
