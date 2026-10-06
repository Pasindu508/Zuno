import XCTest
@testable import Zuno

final class SearchTests: XCTestCase {
    let now = try! Date("2026-10-06T04:30:00Z", strategy: .iso8601) // Tuesday 10:00 in Colombo

    func testMatchesAcrossFields() {
        let event = EventFixtures.event(start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000), university: "University of Jaffna")
        XCTAssertTrue(EventSearch.matches(event, query: "northern", now: now), "title")
        XCTAssertTrue(EventSearch.matches(event, query: "open source", now: now), "organizer")
        XCTAssertTrue(EventSearch.matches(event, query: "technology", now: now), "category")
        XCTAssertTrue(EventSearch.matches(event, query: "innovation hall", now: now), "venue")
        XCTAssertTrue(EventSearch.matches(event, query: "colombo", now: now), "city")
        XCTAssertTrue(EventSearch.matches(event, query: "jaffna university", now: now), "university, any word order")
        XCTAssertTrue(EventSearch.matches(event, query: "CLOUD", now: now), "tags, case-insensitive")
        XCTAssertTrue(EventSearch.matches(event, query: "tomorrow", now: now), "date keyword")
        XCTAssertTrue(EventSearch.matches(event, query: "oct", now: now), "month name")
        XCTAssertFalse(EventSearch.matches(event, query: "galle", now: now))
        XCTAssertFalse(EventSearch.matches(event, query: "today", now: now))
    }

    func testRankingPrefersTitleMatches() {
        let a = EventFixtures.event(title: "Design Systems in Practice", start: now.addingTimeInterval(3 * 86_400), end: now.addingTimeInterval(3 * 86_400 + 7200))
        var b = EventFixtures.event(title: "Startup Pitch Night", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000))
        b.summary = "Founders talk about design"
        let ranked = EventSearch.rank([b, a], query: "design")
        XCTAssertEqual(ranked.first?.title, "Design Systems in Practice")
    }
}

final class FilterTests: XCTestCase {
    let now = try! Date("2026-10-06T04:30:00Z", strategy: .iso8601) // Tuesday

    func testPriceFormatAvailabilityAndCategory() {
        let free = EventFixtures.event(start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000))
        let paidOnline = EventFixtures.event(category: "music", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000),
                                             isFree: false, remaining: 0, format: .online)
        var filters = EventFilters()
        filters.price = .free
        XCTAssertTrue(filters.matches(free, now: now))
        XCTAssertFalse(filters.matches(paidOnline, now: now))
        filters = EventFilters(); filters.format = .online
        XCTAssertTrue(filters.matches(paidOnline, now: now))
        XCTAssertFalse(filters.matches(free, now: now))
        filters = EventFilters(); filters.availableOnly = true
        XCTAssertFalse(filters.matches(paidOnline, now: now), "sold out hidden")
        filters = EventFilters(); filters.categoryIDs = ["music"]
        XCTAssertTrue(filters.matches(paidOnline, now: now))
        XCTAssertEqual(filters.activeCount, 1)
    }

    func testDistanceAndCity() {
        let colombo = EventFixtures.event(start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000))
        let jaffna = EventFixtures.event(city: "Jaffna", start: now.addingTimeInterval(86_400), end: now.addingTimeInterval(90_000),
                                         location: GeoPoint(latitude: 9.6615, longitude: 80.0255))
        var filters = EventFilters()
        filters.origin = SriLankaLocations.place(named: "Colombo")!.location
        filters.radiusKm = 50
        XCTAssertTrue(filters.matches(colombo, now: now))
        XCTAssertFalse(filters.matches(jaffna, now: now))
        filters = EventFilters(); filters.cities = ["Jaffna"]
        XCTAssertTrue(filters.matches(jaffna, now: now))
        XCTAssertFalse(filters.matches(colombo, now: now))
        let distance = GeoPoint(latitude: 6.9271, longitude: 79.8612).distance(to: GeoPoint(latitude: 9.6615, longitude: 80.0255))
        XCTAssertEqual(distance, 304, accuracy: 6, "Colombo–Jaffna is about 300 km")
    }

    func testDateRangesInColombo() {
        let saturday = EventFixtures.event(start: now.addingTimeInterval(4 * 86_400), end: now.addingTimeInterval(4 * 86_400 + 3600))
        let nextMonth = EventFixtures.event(start: now.addingTimeInterval(40 * 86_400), end: now.addingTimeInterval(40 * 86_400 + 3600))
        var filters = EventFilters()
        filters.dateRange = .thisWeekend
        XCTAssertTrue(filters.matches(saturday, now: now))
        XCTAssertFalse(filters.matches(nextMonth, now: now))
        filters.dateRange = .thisMonth
        XCTAssertTrue(filters.matches(saturday, now: now))
        XCTAssertFalse(filters.matches(nextMonth, now: now))
        filters.dateRange = .today
        XCTAssertFalse(filters.matches(saturday, now: now))
    }

    func testEndedEventsNeverMatch() {
        let ended = EventFixtures.event(start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-3600))
        XCTAssertFalse(EventFilters().matches(ended, now: now))
    }

    func testServerPayloadKeys() {
        var filters = EventFilters()
        filters.price = .paid
        filters.cities = ["Kandy"]
        filters.availableOnly = true
        filters.dateRange = .today
        let payload = filters.serverPayload(now: now)
        XCTAssertEqual(Set(payload.keys), ["price", "cities", "available_only", "date_from", "date_to"])
    }
}

final class HomeFeedTests: XCTestCase {
    func testSectionsNeverRepeatEvents() {
        let now = Date.now
        let events = (0..<12).map { index in
            EventFixtures.event(category: ["hackathons", "technology", "art", "workshops"][index % 4],
                                start: now.addingTimeInterval(Double(index + 1) * 86_400), end: now.addingTimeInterval(Double(index + 1) * 86_400 + 3600))
        }
        let sections = HomeFeed.sections(from: events, city: "Colombo", preferredCategories: ["technology"], followedOrganizers: [], now: now)
        let ids = sections.flatMap { $0.events.map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(Set(ids), Set(events.map(\.id)), "every upcoming event appears once")
        XCTAssertEqual(sections.first?.kind, .recommended)
    }
}

final class CalendarGroupingTests: XCTestCase {
    func testMonthGridIsMondayFirstSixWeeks() throws {
        let october = try Date("2026-10-15T06:00:00Z", strategy: .iso8601)
        let grid = CalendarGrouping.monthGrid(for: october)
        XCTAssertEqual(grid.count, 42)
        XCTAssertEqual(Calendar.colombo.component(.weekday, from: grid[0].date), 2, "starts on Monday")
        XCTAssertEqual(grid.filter(\.isInDisplayedMonth).count, 31)
    }

    func testMultiDayItemsAppearOnEachDay() throws {
        let start = try Date("2026-10-10T03:00:00Z", strategy: .iso8601)
        let item = CalendarItem(eventID: UUID(), title: "Hackathon", startsAt: start, endsAt: start.addingTimeInterval(36 * 3600),
                                place: "Colombo", source: .registered, cover: nil)
        let map = CalendarGrouping.itemsByDay([item])
        XCTAssertEqual(map.count, 2)
    }

    func testAgendaSkipsPastAndSorts() throws {
        let now = try Date("2026-10-06T04:30:00Z", strategy: .iso8601)
        let past = CalendarItem(eventID: UUID(), title: "Past", startsAt: now.addingTimeInterval(-86_400 * 3), endsAt: now.addingTimeInterval(-86_400 * 3 + 3600),
                                place: "", source: .saved, cover: nil)
        let later = CalendarItem(eventID: UUID(), title: "Later", startsAt: now.addingTimeInterval(86_400 * 5), endsAt: now.addingTimeInterval(86_400 * 5 + 3600),
                                 place: "", source: .saved, cover: nil)
        let soon = CalendarItem(eventID: UUID(), title: "Soon", startsAt: now.addingTimeInterval(86_400), endsAt: now.addingTimeInterval(86_400 + 3600),
                                place: "", source: .registered, cover: nil)
        let agenda = CalendarGrouping.agenda([later, past, soon], from: now)
        XCTAssertEqual(agenda.map { $0.items.first?.title }, ["Soon", "Later"])
    }
}

final class TicketGroupingTests: XCTestCase {
    func testSegments() {
        let now = Date.now
        func ticket(_ status: TicketStatus, endsIn: TimeInterval) -> Ticket {
            Ticket(id: UUID(), code: "ZN-AAAA-BBBB", qrPayload: "zuno:t:x", status: status, tierName: "General", attendeeName: "A",
                   issuedAt: now, checkedInAt: nil, registrationReference: "ZR-1",
                   orderID: nil, event: TicketEventInfo(id: UUID(), title: "E", startsAt: now.addingTimeInterval(endsIn - 3600),
                                                         endsAt: now.addingTimeInterval(endsIn), venueName: nil, city: nil, cover: nil,
                                                         coverAlt: nil, status: .published, categoryID: "art"))
        }
        let groups = TicketSegment.group([ticket(.valid, endsIn: 86_400), ticket(.checkedIn, endsIn: -86_400), ticket(.refunded, endsIn: 86_400)], now: now)
        XCTAssertEqual(groups[.upcoming]?.count, 1)
        XCTAssertEqual(groups[.past]?.count, 1)
        XCTAssertEqual(groups[.cancelled]?.count, 1)
    }
}

final class PrimaryActionTests: XCTestCase {
    private func detail(free: Bool = true, remaining: Int = 10, status: RegistrationStatus? = nil, tiers: [TicketTier] = [],
                        start: TimeInterval = 86_400, eventStatus: EventStatus = .published, format: EventFormat = .physical) -> EventDetail {
        let now = Date.now
        var event = EventFixtures.event(start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + 3600),
                                        isFree: free, remaining: remaining, format: format)
        event.status = eventStatus
        return EventDetail(summary: event, description: "", addressLine: nil, onlineURL: nil, agenda: [], speakers: [], refundPolicy: nil,
                           registrationOpensAt: nil, registrationClosesAt: nil, organizerVerified: true, tiers: tiers, questions: [], gallery: [],
                           viewer: ViewerState(isSaved: false, registrationStatus: status, registrationID: nil, isOrganizer: false))
    }

    func testLabelsFollowEventState() {
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail()), .registerFree)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(format: .online)), .joinOnlineEvent)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(remaining: 0)), .joinWaitlist)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(status: .confirmed)), .viewTicket)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(status: .waitlisted)), .onWaitlist)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(start: -7200)), .eventEnded)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(eventStatus: .cancelled)), .eventCancelled)
        let onSale = TicketTier(id: UUID(), name: "G", description: "", price: .lkr(50_000), quantity: 10, remaining: 3, maxPerOrder: 2,
                                salesStartAt: nil, salesEndAt: nil, onSale: true)
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(free: false, tiers: [onSale])), .buyTicket)
        var soldOut = onSale
        soldOut.remaining = 0
        XCTAssertEqual(EventPrimaryAction.resolve(for: detail(free: false, tiers: [soldOut])), .soldOut,
                       "paid events have no waitlist")
        XCTAssertEqual(EventPrimaryAction.buyTicket.title, "Buy ticket")
        XCTAssertEqual(EventPrimaryAction.registrationClosed.title, "Registration closed")
    }
}

final class CheckInStateMachineTests: XCTestCase {
    func testPermissionFlow() {
        var machine = CheckInStateMachine()
        machine.handle(.startRequested(permission: .notDetermined))
        XCTAssertEqual(machine.phase, .requestingPermission)
        machine.handle(.permissionResolved(granted: false))
        XCTAssertEqual(machine.phase, .permissionDenied)
        machine.handle(.permissionResolved(granted: true))
        XCTAssertEqual(machine.phase, .scanning)
    }

    func testValidationAndDuplicateScanPrevention() {
        var machine = CheckInStateMachine()
        let t0 = Date.now
        machine.handle(.startRequested(permission: .authorized))
        XCTAssertTrue(machine.handle(.codeDetected("zuno:t:abc", isOnline: true), now: t0))
        XCTAssertFalse(machine.handle(.codeDetected("zuno:t:abc", isOnline: true), now: t0), "busy while validating")
        XCTAssertFalse(machine.handle(.codeDetected("zuno:t:other", isOnline: true), now: t0), "one validation at a time")
        let outcome = CheckInOutcome(result: .valid, attendeeName: "A", tierName: "G", checkedInAt: t0)
        machine.handle(.validationFinished(code: "zuno:t:abc", outcome: outcome))
        XCTAssertEqual(machine.phase, .result(code: "zuno:t:abc", outcome: outcome))
        machine.handle(.dismissResult, now: t0.addingTimeInterval(1))
        XCTAssertEqual(machine.phase, .scanning)
        XCTAssertFalse(machine.handle(.codeDetected("zuno:t:abc", isOnline: true), now: t0.addingTimeInterval(2)),
                       "the same QR still in frame is ignored")
        XCTAssertTrue(machine.handle(.codeDetected("zuno:t:abc", isOnline: true), now: t0.addingTimeInterval(10)),
                      "a deliberate re-scan later reaches the server (which reports already used)")
        machine.handle(.validationFinished(code: "zuno:t:abc", outcome: outcome))
        machine.handle(.dismissResult, now: t0.addingTimeInterval(11))
        XCTAssertTrue(machine.handle(.codeDetected("zuno:t:abc", isOnline: true, manual: true), now: t0.addingTimeInterval(11.5)),
                      "a typed code is always submitted")
    }

    func testNetworkFailureAndOfflineRestriction() {
        var machine = CheckInStateMachine()
        machine.handle(.startRequested(permission: .authorized))
        XCTAssertFalse(machine.handle(.codeDetected("ZN-AAAA-BBBB", isOnline: false)))
        XCTAssertEqual(machine.phase, .offlineRestricted, "never admits without the server")
        machine.handle(.connectivityChanged(isOnline: true))
        XCTAssertEqual(machine.phase, .scanning)
        XCTAssertTrue(machine.handle(.codeDetected("ZN-AAAA-BBBB", isOnline: true)))
        machine.handle(.validationFailed(code: "ZN-AAAA-BBBB"))
        XCTAssertEqual(machine.phase, .networkError(code: "ZN-AAAA-BBBB"))
        XCTAssertTrue(machine.handle(.codeDetected("ZN-AAAA-BBBB", isOnline: true)), "retry allowed after a network error")
    }
}
