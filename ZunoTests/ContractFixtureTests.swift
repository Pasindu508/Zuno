import XCTest
@testable import Zuno

/// Decodes JSON produced by the real SQL functions (exported from a PostgreSQL 17 cluster
/// with the migrations and seed applied — `scripts/export-contract-fixtures.py`) with the
/// app's DTOs. A server/client shape mismatch fails here.
final class ContractFixtureTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        do {
            return try JSONDecoder.zunoSnake.decode(T.self, from: try fixture(name))
        } catch {
            XCTFail("\(name).json does not decode as \(T.self): \(error)")
            throw error
        }
    }

    func testCatalogueAndSearch() throws {
        let categories = try decode([CategoryRow].self, "categories").map(\.domain)
        XCTAssertEqual(categories.count, 10)
        XCTAssertEqual(categories.first?.id, "hackathons")
        XCTAssertEqual(categories.first?.symbolName, "laptopcomputer")

        let events = try decode([EventCardRow].self, "search_events_anon").map(\.domain)
        XCTAssertGreaterThanOrEqual(events.count, 14)
        XCTAssertTrue(events.allSatisfy { $0.status == .published })
        XCTAssertTrue(events.contains { !$0.isFree && $0.minPrice != nil })
        XCTAssertTrue(events.allSatisfy { $0.cover != nil })
        XCTAssertEqual(events, events.sorted { $0.startsAt < $1.startsAt }, "ordered by start time")

        let filtered = try decode([EventCardRow].self, "search_events_filtered").map(\.domain)
        XCTAssertTrue(filtered.allSatisfy { !$0.isFree && $0.seatsRemaining > 0 })
    }

    func testEventDetails() throws {
        let paid = try decode(EventDetailEnvelope.self, "event_detail_paid").domain
        XCTAssertEqual(paid.summary.title, "Kandyan Drumming Circle")
        XCTAssertFalse(paid.tiers.isEmpty)
        XCTAssertTrue(paid.viewer.isSaved, "the development user saved this event")
        XCTAssertEqual(EventPrimaryAction.resolve(for: paid), .buyTicket)

        let free = try decode(EventDetailEnvelope.self, "event_detail_free").domain
        XCTAssertTrue(free.summary.isFree)
        XCTAssertFalse(free.agenda.isEmpty)
        XCTAssertFalse(free.questions.isEmpty)
        XCTAssertFalse(free.speakers.isEmpty)
    }

    func testRegistration() throws {
        let quote = try decode(QuoteRow.self, "quote_free_registration").domain
        XCTAssertEqual(quote.allowanceLimit, 15)
        XCTAssertEqual(quote.allowanceRemaining, 2)
        XCTAssertEqual(quote.walletBalance, .lkr(14_000))

        let confirmation = try decode(RegistrationResultRow.self, "register_for_free_event").domain
        XCTAssertEqual(confirmation.status, .confirmed)
        XCTAssertTrue(confirmation.reference.hasPrefix("ZR-"))
        XCTAssertNotNil(confirmation.ticketID)

        let history = try decode([RegistrationHistoryRow].self, "my_registrations").map(\.domain)
        XCTAssertFalse(history.isEmpty)
    }

    func testTicketsWalletNotificationsProfile() throws {
        let tickets = try decode([TicketRow].self, "my_tickets").map(\.domain)
        XCTAssertFalse(tickets.isEmpty)
        XCTAssertTrue(tickets.allSatisfy { $0.qrPayload.hasPrefix("zuno:t:") && $0.code.hasPrefix("ZN-") })

        let summary = try decode(WalletSummaryRow.self, "wallet_summary").domain
        XCTAssertEqual(summary.balance, .lkr(14_000))
        XCTAssertEqual(summary.extraFee, .lkr(250))

        let ledger = try decode([LedgerRow].self, "wallet_ledger").map(\.domain)
        let posted = ledger.filter { $0.status == .posted }.reduce(Int64(0)) { $0 + $1.amount.minorUnits }
        XCTAssertEqual(posted, summary.balance.minorUnits, "the ledger explains the balance")

        _ = try decode([NotificationDTO].self, "notifications")
        let preferences = try JSONDecoder.zuno.decode([NotificationPreferences].self, from: try fixture("notification_preferences"))
        XCTAssertEqual(preferences.count, 1)

        let profile = try XCTUnwrap(try decode([ProfileRow].self, "profile").first?.domain)
        XCTAssertEqual(profile.identityStatus, .verifiedUnique)
        XCTAssertTrue(profile.isComplete)
    }

    func testOrganizer() throws {
        let dashboard = try decode(DashboardRow.self, "organizer_dashboard").domain
        XCTAssertEqual(dashboard.organizer.verification, .verified)
        XCTAssertFalse(dashboard.events.isEmpty)
        _ = try decode(EventStatsRow.self, "organizer_event_stats").domain
        _ = try decode([AttendeeRowDTO].self, "organizer_attendees").map(\.domain)
        let settlements = try decode([SettlementRowDTO].self, "organizer_settlements").map(\.domain)
        XCTAssertTrue(settlements.allSatisfy { $0.net.minorUnits == $0.gross.minorUnits - $0.commission.minorUnits })
        let checkIn = try decode(CheckInRow.self, "check_in_invalid").domain
        XCTAssertEqual(checkIn.result, .invalid)
        let venues = try decode([VenueRow].self, "venues").map(\.domain)
        XCTAssertFalse(venues.isEmpty)
    }
}
