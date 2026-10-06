import XCTest
@testable import Zuno

/// Exercises the server rules as implemented by the development backend (the same rules
/// are enforced authoritatively in SQL; see supabase/tests for the database assertions).
final class BackendRulesTests: XCTestCase {
    private let devUser = UUID(uuidString: "b0000000-0000-4000-8000-0000000000aa")!
    private let freeHackathon = UUID(uuidString: "e1000000-0000-4000-8000-000000000001")!
    private let freeWorkshop = UUID(uuidString: "e1000000-0000-4000-8000-000000000002")!
    private let photoWalk = UUID(uuidString: "e1000000-0000-4000-8000-000000000004")!
    private let jaffna = UUID(uuidString: "e1000000-0000-4000-8000-000000000005")!
    private let careers = UUID(uuidString: "e1000000-0000-4000-8000-000000000007")!
    private let robotics = UUID(uuidString: "e1000000-0000-4000-8000-000000000010")!
    private let designOnline = UUID(uuidString: "e1000000-0000-4000-8000-000000000013")!
    private let kandyan = UUID(uuidString: "e1000000-0000-4000-8000-000000000003")!
    private let soldOutRun = UUID(uuidString: "e1000000-0000-4000-8000-000000000009")!

    private func signedInBackend(organizer: Bool = false) async -> DevelopmentBackend {
        let backend = await DevelopmentBackend(makeDevelopmentUserOrganizer: organizer)
        await backend.setLatency(.zero)
        await backend.signIn(userID: devUser, email: "dev.attendee@zuno.example", displayName: nil, completeProfile: true)
        return backend
    }

    private func answers(for eventID: UUID, backend: DevelopmentBackend) async throws -> [RegistrationAnswer] {
        let detail = try await backend.eventDetail(id: eventID)
        return detail.questions.filter(\.required).map { question in
            switch question.kind {
            case .singleChoice, .multiChoice: RegistrationAnswer(questionID: question.id, value: .choices([question.options[0]]))
            case .yesNo: RegistrationAnswer(questionID: question.id, value: .bool(true))
            case .shortText, .longText: RegistrationAnswer(questionID: question.id, value: .text("Engineering"))
            }
        }
    }

    func testMonthlyAllowanceThenExactWalletDeduction() async throws {
        let backend = await signedInBackend()
        // Seed: 13 of 15 used, wallet LKR 140.00.
        var quote = try await backend.quoteFreeRegistration(eventID: freeHackathon)
        XCTAssertEqual(quote.allowanceRemaining, 2)
        XCTAssertEqual(quote.fee, .zero)

        _ = try await backend.registerFree(eventID: freeHackathon, answers: try await answers(for: freeHackathon, backend: backend),
                                           expectedFee: .zero, idempotencyKey: "k1")
        let second = try await backend.registerFree(eventID: jaffna, answers: [], expectedFee: .zero, idempotencyKey: "k2")
        XCTAssertEqual(second.allowanceRemaining, 0)
        XCTAssertEqual(second.walletBalance, .lkr(14_000), "the 15th is still free")

        quote = try await backend.quoteFreeRegistration(eventID: careers)
        XCTAssertEqual(quote.fee, .lkr(250))
        XCTAssertTrue(quote.requiresWalletDeduction)
        XCTAssertEqual(quote.balanceAfter, .lkr(13_750))

        let third = try await backend.registerFree(eventID: careers, answers: try await answers(for: careers, backend: backend),
                                                   expectedFee: .lkr(250), idempotencyKey: "k3")
        XCTAssertEqual(third.fee, .lkr(250))
        XCTAssertEqual(third.walletBalance, .lkr(13_750))
        let ledger = try await backend.transactions()
        XCTAssertEqual(ledger.first?.type, .freeRegistrationFee)
        XCTAssertEqual(ledger.first?.amount, .lkr(-250))
        XCTAssertEqual(ledger.first?.balanceAfter, .lkr(13_750))
    }

    func testFeeMustMatchWhatTheUserConfirmed() async throws {
        let backend = await signedInBackend()
        _ = try await backend.registerFree(eventID: jaffna, answers: [], expectedFee: .zero, idempotencyKey: "a")
        _ = try await backend.registerFree(eventID: designOnline, answers: [], expectedFee: .zero, idempotencyKey: "b")
        do {
            _ = try await backend.registerFree(eventID: careers, answers: try await answers(for: careers, backend: backend),
                                               expectedFee: .zero, idempotencyKey: "c")
            XCTFail("a stale zero-fee confirmation must be rejected")
        } catch {
            XCTAssertEqual(error as? ZunoError, .feeChanged)
        }
    }

    func testInsufficientBalanceRollsBackEverything() async throws {
        let backend = await signedInBackend()
        await backend.setBalance(100, for: devUser)
        _ = try await backend.registerFree(eventID: jaffna, answers: [], expectedFee: .zero, idempotencyKey: "a")
        _ = try await backend.registerFree(eventID: designOnline, answers: [], expectedFee: .zero, idempotencyKey: "b")
        let before = try await backend.eventDetail(id: careers).summary.seatsRemaining
        let ticketsBefore = try await backend.tickets().count
        do {
            _ = try await backend.registerFree(eventID: careers, answers: try await answers(for: careers, backend: backend),
                                               expectedFee: .lkr(250), idempotencyKey: "c")
            XCTFail("expected insufficient balance")
        } catch {
            XCTAssertEqual(error as? ZunoError, .registration(.insufficientBalance))
        }
        let after = try await backend.eventDetail(id: careers).summary.seatsRemaining
        XCTAssertEqual(before, after, "no seat taken")
        let ticketsAfter = try await backend.tickets().count
        XCTAssertEqual(ticketsBefore, ticketsAfter, "no ticket issued")
        let summary = try await backend.summary()
        XCTAssertEqual(summary.balance, .lkr(100), "no debit")
    }

    func testDuplicateRegistrationAndIdempotentReplay() async throws {
        let backend = await signedInBackend()
        let first = try await backend.registerFree(eventID: jaffna, answers: [], expectedFee: .zero, idempotencyKey: "same")
        let replay = try await backend.registerFree(eventID: jaffna, answers: [], expectedFee: .zero, idempotencyKey: "same")
        XCTAssertEqual(first, replay, "a retried request returns the original result")
        do {
            _ = try await backend.registerFree(eventID: jaffna, answers: [], expectedFee: .zero, idempotencyKey: "different")
            XCTFail("expected duplicate rejection")
        } catch {
            XCTAssertEqual(error as? ZunoError, .registration(.alreadyRegistered))
        }
    }

    func testRequiredAnswersAreEnforced() async throws {
        let backend = await signedInBackend()
        do {
            _ = try await backend.registerFree(eventID: robotics, answers: [], expectedFee: .zero, idempotencyKey: "x")
            XCTFail("expected answers_invalid")
        } catch {
            XCTAssertEqual(error as? ZunoError, .answersInvalid)
        }
    }

    func testCapacityWaitlistAndOfferOnCancellation() async throws {
        let backend = await signedInBackend()
        // Galle photo walk: 25 capacity, 22 taken.
        let other = [UUID(), UUID(), UUID()]
        for (index, user) in other.enumerated() {
            await backend.signIn(userID: user, email: nil, displayName: "Guest \(index)", completeProfile: true)
            _ = try await backend.registerFree(eventID: photoWalk, answers: [], expectedFee: .zero, idempotencyKey: "g\(index)")
        }
        await backend.signIn(userID: devUser, email: nil, displayName: nil, completeProfile: true)
        let quote = try await backend.quoteFreeRegistration(eventID: photoWalk)
        XCTAssertEqual(quote.reason, .soldOut)
        let waitlist = try await backend.joinWaitlist(eventID: photoWalk)
        XCTAssertEqual(waitlist.position, 1)

        await backend.signIn(userID: other[0], email: nil, displayName: nil, completeProfile: true)
        let mine = try await backend.registrations().first { $0.event.id == photoWalk }!
        try await backend.cancelRegistration(id: mine.id)

        await backend.signIn(userID: devUser, email: nil, displayName: nil, completeProfile: true)
        let notifications = try await backend.notifications()
        XCTAssertEqual(notifications.first?.kind, .waitlistMovement, "next person is offered the seat")
        let offered = try await backend.eventDetail(id: photoWalk)
        XCTAssertEqual(offered.viewer.registrationStatus, .offered)
        let confirmation = try await backend.registerFree(eventID: photoWalk, answers: [], expectedFee: .zero, idempotencyKey: "offer")
        XCTAssertEqual(confirmation.status, .confirmed)
    }

    func testPaidCheckoutReservesInventoryAndIssuesTicketsOnlyAfterVerifiedPayment() async throws {
        let backend = await signedInBackend()
        let detail = try await backend.eventDetail(id: kandyan)
        let tier = detail.tiers[0]
        let ticketsBefore = try await backend.tickets().count
        let session = try await backend.createCheckout(CheckoutRequest(
            purpose: .tickets(eventID: kandyan, items: [CheckoutItem(tierID: tier.id, quantity: 2)], answers: []),
            phone: "0771234567", idempotencyKey: "order-1"))
        XCTAssertEqual(session.summary.total, .lkr(300_000))
        XCTAssertEqual(session.summary.commission, .lkr(15_000))
        let reserved = try await backend.eventDetail(id: kandyan).tiers[0].remaining
        XCTAssertEqual(reserved, tier.remaining - 2, "inventory held while pending")
        let afterCreate = try await backend.tickets().count
        XCTAssertEqual(afterCreate, ticketsBefore, "no tickets before verification")

        let replay = try await backend.createCheckout(CheckoutRequest(
            purpose: .tickets(eventID: kandyan, items: [CheckoutItem(tierID: tier.id, quantity: 2)], answers: []),
            phone: "0771234567", idempotencyKey: "order-1"))
        XCTAssertEqual(replay.orderID, session.orderID, "same idempotency key → same order")

        try await backend.simulateGatewayNotification(orderID: session.orderID, statusCode: 2)
        try await backend.simulateGatewayNotification(orderID: session.orderID, statusCode: 2) // duplicate callback
        let order = try await backend.order(id: session.orderID)
        XCTAssertEqual(order.status, .paid)
        let afterPaid = try await backend.tickets().count
        XCTAssertEqual(afterPaid, ticketsBefore + 2, "exactly one ticket per seat, even with duplicate callbacks")
    }

    func testFailedAndCancelledPaymentsReleaseInventory() async throws {
        let backend = await signedInBackend()
        let tier = try await backend.eventDetail(id: kandyan).tiers[0]
        for (key, code) in [("f", -2), ("c", -1)] {
            let session = try await backend.createCheckout(CheckoutRequest(
                purpose: .tickets(eventID: kandyan, items: [CheckoutItem(tierID: tier.id, quantity: 1)], answers: []),
                phone: "0771234567", idempotencyKey: key))
            try await backend.simulateGatewayNotification(orderID: session.orderID, statusCode: code)
            let status = try await backend.order(id: session.orderID).status
            XCTAssertEqual(status, code == -2 ? .failed : .cancelled)
            // A late success notification for a terminal order is ignored.
            try await backend.simulateGatewayNotification(orderID: session.orderID, statusCode: 2)
            let still = try await backend.order(id: session.orderID).status
            XCTAssertNotEqual(still, .paid)
        }
        let remaining = try await backend.eventDetail(id: kandyan).tiers[0].remaining
        XCTAssertEqual(remaining, tier.remaining)
    }

    func testSoldOutTierCannotBeOrdered() async throws {
        let backend = await signedInBackend()
        let tier = try await backend.eventDetail(id: soldOutRun).tiers[0]
        do {
            _ = try await backend.createCheckout(CheckoutRequest(
                purpose: .tickets(eventID: soldOutRun, items: [CheckoutItem(tierID: tier.id, quantity: 1)], answers: []),
                phone: "0771234567", idempotencyKey: "s"))
            XCTFail("expected sold out")
        } catch {
            XCTAssertEqual(error as? ZunoError, .registration(.soldOut))
        }
    }

    func testWalletTopUpPostsOnlyAfterSuccess() async throws {
        let backend = await signedInBackend()
        let declined = try await backend.createCheckout(CheckoutRequest(purpose: .walletTopUp(amount: .rupees(500)), phone: "0771234567", idempotencyKey: "t1"))
        var summary = try await backend.summary()
        XCTAssertEqual(summary.pendingTopUps, .rupees(500))
        try await backend.simulateGatewayNotification(orderID: declined.orderID, statusCode: -2)
        summary = try await backend.summary()
        XCTAssertEqual(summary.balance, .lkr(14_000))
        XCTAssertEqual(summary.pendingTopUps, .zero)

        let approved = try await backend.createCheckout(CheckoutRequest(purpose: .walletTopUp(amount: .rupees(500)), phone: "0771234567", idempotencyKey: "t2"))
        try await backend.simulateGatewayNotification(orderID: approved.orderID, statusCode: 2)
        summary = try await backend.summary()
        XCTAssertEqual(summary.balance, .lkr(64_000))
        let ledger = try await backend.transactions()
        XCTAssertEqual(ledger.filter { $0.status == .failed }.count, 2, "seeded decline + this decline")
    }

    func testNICDuplicateDetectionAcrossFormats() async throws {
        let backend = await signedInBackend()
        let duplicate = try await backend.submitNationalIdentifier("851234567V")
        XCTAssertEqual(duplicate, .duplicate, "old-format number canonicalises to an existing digest")
        let other = UUID()
        await backend.signIn(userID: other, email: nil, displayName: "New", completeProfile: false)
        let fresh = try await backend.submitNationalIdentifier("2001 2345 6789")
        XCTAssertEqual(fresh, .verifiedUnique)
        let profile = try await backend.currentProfile()
        XCTAssertEqual(profile?.identityStatus, .verifiedUnique)
        do {
            _ = try await backend.submitNationalIdentifier("12345")
            XCTFail("invalid format must be rejected")
        } catch {}
    }

    func testCheckInTransitions() async throws {
        let backend = await signedInBackend(organizer: true)
        let valid = try await backend.checkIn(eventID: freeHackathon, code: "zn-test-0001")
        XCTAssertEqual(valid.result, .valid)
        XCTAssertEqual(valid.attendeeName, "Test Attendee")
        let again = try await backend.checkIn(eventID: freeHackathon, code: "zuno:t:test-token-0001")
        XCTAssertEqual(again.result, .alreadyUsed)
        let invalid = try await backend.checkIn(eventID: freeHackathon, code: "ZN-NOPE-NOPE")
        XCTAssertEqual(invalid.result, .invalid)
        let junior = UUID(uuidString: "e1000000-0000-4000-8000-000000000014")!
        let wrong = try await backend.checkIn(eventID: junior, code: "ZN-TEST-0001")
        XCTAssertEqual(wrong.result, .wrongEvent)
        do {
            _ = try await backend.checkIn(eventID: kandyan, code: "ZN-TEST-0001")
            XCTFail("only the event's organizer may check in")
        } catch {}
    }

    func testOrganizerPublishValidation() async throws {
        let backend = await signedInBackend(organizer: true)
        let dashboard = try await backend.dashboard()
        let organizerID = try XCTUnwrap(dashboard?.organizer.id)
        var draft = EventDraft(organizerID: organizerID)
        draft.title = "Swift"
        _ = try await backend.saveEventDraft(draft)
        do {
            try await backend.submitForPublish(eventID: draft.id)
            XCTFail("unpaid fee must block publishing")
        } catch {}
        let session = try await backend.createCheckout(CheckoutRequest(purpose: .eventCreationFee(eventID: draft.id), phone: "0771234567", idempotencyKey: "fee"))
        try await backend.simulateGatewayNotification(orderID: session.orderID, statusCode: 2)
        do {
            try await backend.submitForPublish(eventID: draft.id)
            XCTFail("incomplete draft must fail validation")
        } catch {
            guard case .server(let code, _)? = error as? ZunoError else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "validation_failed")
        }
        draft = try await backend.eventDraft(id: draft.id)
        draft.title = "Swift Concurrency Clinic"
        draft.summary = "A practical evening on actors and tasks"
        draft.description = "Bring a laptop and a project. We'll refactor real code to Swift 6 strict concurrency together."
        draft.venueID = try await backend.venues().first?.id
        draft.coverPath = "seed-climate-ai-hackathon"
        _ = try await backend.saveEventDraft(draft)
        try await backend.submitForPublish(eventID: draft.id)
        let published = try await backend.eventDraft(id: draft.id)
        XCTAssertEqual(published.status, .published)
    }
}

extension DevelopmentBackend {
    func setLatency(_ duration: Duration) { simulatedLatency = duration }
}
