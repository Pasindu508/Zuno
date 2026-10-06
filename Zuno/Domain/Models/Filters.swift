import Foundation

enum DateRangeOption: Hashable, Sendable, Codable {
    case any, today, thisWeek, thisWeekend, thisMonth
    case custom(from: Date, to: Date)

    static let presets: [DateRangeOption] = [.any, .today, .thisWeekend, .thisWeek, .thisMonth]

    var title: String {
        switch self {
        case .any: String(localized: "Any date")
        case .today: String(localized: "Today")
        case .thisWeek: String(localized: "This week")
        case .thisWeekend: String(localized: "This weekend")
        case .thisMonth: String(localized: "This month")
        case .custom: String(localized: "Custom")
        }
    }

    /// The concrete interval in Asia/Colombo for `now`.
    func interval(now: Date, calendar: Calendar = .colombo) -> DateInterval? {
        switch self {
        case .any:
            return nil
        case .today:
            let start = calendar.startOfDay(for: now)
            return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        case .thisWeek:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return DateInterval(start: max(week.start, calendar.startOfDay(for: now)), end: week.end)
        case .thisWeekend:
            let startOfToday = calendar.startOfDay(for: now)
            let weekday = calendar.component(.weekday, from: now) // 1 = Sunday, 7 = Saturday
            let daysUntilSaturday = weekday == 1 ? -1 : 7 - weekday
            let saturday = calendar.date(byAdding: .day, value: daysUntilSaturday, to: startOfToday)!
            let monday = calendar.date(byAdding: .day, value: 2, to: saturday)!
            return DateInterval(start: max(saturday, startOfToday), end: monday)
        case .thisMonth:
            guard let month = calendar.dateInterval(of: .month, for: now) else { return nil }
            return DateInterval(start: max(month.start, calendar.startOfDay(for: now)), end: month.end)
        case .custom(let from, let to):
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!
            return DateInterval(start: start, end: end)
        }
    }
}

enum PriceFilter: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case any, free, paid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: String(localized: "Any price")
        case .free: String(localized: "Free")
        case .paid: String(localized: "Paid")
        }
    }
}

enum FormatFilter: String, Hashable, Sendable, Codable, CaseIterable, Identifiable {
    case any, physical, online
    var id: String { rawValue }
    var title: String {
        switch self {
        case .any: String(localized: "Any format")
        case .physical: String(localized: "In person")
        case .online: String(localized: "Online")
        }
    }
}

struct EventFilters: Hashable, Sendable, Codable {
    var dateRange: DateRangeOption = .any
    var cities: Set<String> = []
    var origin: GeoPoint?
    var radiusKm: Double?
    var price: PriceFilter = .any
    var format: FormatFilter = .any
    var availableOnly = false
    var organizerIDs: Set<UUID> = []
    var categoryIDs: Set<String> = []
    var university: String?

    static let none = EventFilters()

    var activeCount: Int {
        var count = 0
        if dateRange != .any { count += 1 }
        if !cities.isEmpty { count += 1 }
        if radiusKm != nil { count += 1 }
        if price != .any { count += 1 }
        if format != .any { count += 1 }
        if availableOnly { count += 1 }
        if !organizerIDs.isEmpty { count += 1 }
        if !categoryIDs.isEmpty { count += 1 }
        if university != nil { count += 1 }
        return count
    }

    var isEmpty: Bool { activeCount == 0 }

    /// Local evaluation, identical in meaning to the server's `search_events` filters.
    func matches(_ event: EventSummary, now: Date = .now, calendar: Calendar = .colombo) -> Bool {
        if event.hasEnded(now: now) || event.status != .published { return false }
        if let interval = dateRange.interval(now: now, calendar: calendar) {
            // Overlap: the event runs at some point inside the interval.
            if !(event.startsAt < interval.end && event.endsAt > interval.start) { return false }
        }
        if !cities.isEmpty {
            guard let city = event.city, cities.contains(city) || cities.contains(event.district ?? "") else { return false }
        }
        if let radiusKm, let origin {
            guard let location = event.location, location.distance(to: origin) <= radiusKm else { return false }
        }
        switch price {
        case .any: break
        case .free: if !event.isFree { return false }
        case .paid: if event.isFree { return false }
        }
        switch format {
        case .any: break
        case .physical: if event.format == .online { return false }
        case .online: if event.format == .physical { return false }
        }
        if availableOnly, event.seatsRemaining <= 0 { return false }
        if !organizerIDs.isEmpty, !organizerIDs.contains(event.organizerID) { return false }
        if !categoryIDs.isEmpty, !categoryIDs.contains(event.categoryID) { return false }
        if let university, event.university != university { return false }
        return true
    }
}

/// Free-text event search over name, organizer, category, venue, city, university,
/// tags and natural date keywords ("today", "weekend", "october").
enum EventSearch {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func tokens(_ query: String) -> [String] {
        normalize(query).split { $0.isWhitespace || $0 == "," }.map(String.init).filter { !$0.isEmpty }
    }

    static func matches(_ event: EventSummary, query: String, now: Date = .now, calendar: Calendar = .colombo) -> Bool {
        let terms = tokens(query)
        guard !terms.isEmpty else { return true }
        let haystack = normalize([
            event.title, event.summary, event.organizerName, event.categoryName, event.categoryID,
            event.venueName ?? "", event.city ?? "", event.district ?? "", event.university ?? "",
            event.tags.joined(separator: " "), event.format == .online ? "online" : "",
        ].joined(separator: " "))
        return terms.allSatisfy { term in
            haystack.contains(term) || dateKeywordMatches(term, event: event, now: now, calendar: calendar)
        }
    }

    /// Ranks title hits above other fields, then sooner events first.
    static func rank(_ events: [EventSummary], query: String) -> [EventSummary] {
        let terms = tokens(query)
        func score(_ event: EventSummary) -> Int {
            let title = normalize(event.title)
            return terms.reduce(0) { $0 + (title.contains($1) ? 2 : 0) + (title.hasPrefix($1) ? 1 : 0) }
        }
        return events.sorted { lhs, rhs in
            let (l, r) = (score(lhs), score(rhs))
            return l == r ? lhs.startsAt < rhs.startsAt : l > r
        }
    }

    private static func dateKeywordMatches(_ term: String, event: EventSummary, now: Date, calendar: Calendar) -> Bool {
        let option: DateRangeOption? = switch term {
        case "today", "tonight": .today
        case "weekend": .thisWeekend
        case "week": .thisWeek
        case "month": .thisMonth
        default: nil
        }
        if let interval = option?.interval(now: now, calendar: calendar) {
            return event.startsAt < interval.end && event.endsAt > interval.start
        }
        if term == "tomorrow" {
            let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let end = calendar.date(byAdding: .day, value: 1, to: start)!
            return event.startsAt < end && event.endsAt > start
        }
        // Month names in English ("oct", "october").
        let symbols = calendar.monthSymbols.map(normalize) + calendar.shortMonthSymbols.map(normalize)
        if term.count >= 3, let index = symbols.firstIndex(where: { $0.hasPrefix(term) }) {
            let month = index % 12 + 1
            return calendar.component(.month, from: event.startsAt) == month
        }
        return false
    }
}

/// Feed sections for Home, derived from one vertical list of upcoming events.
enum HomeFeed {
    enum SectionKind: String, CaseIterable, Sendable, Hashable {
        case recommended, upcoming, thisWeek, free, hackathons, university, workshops, culture, techMeetups, followedOrganizers

        var title: String {
            switch self {
            case .recommended: String(localized: "Recommended near you")
            case .upcoming: String(localized: "Upcoming")
            case .thisWeek: String(localized: "This week")
            case .free: String(localized: "Free events")
            case .hackathons: String(localized: "Hackathons")
            case .university: String(localized: "University events")
            case .workshops: String(localized: "Workshops")
            case .culture: String(localized: "Cultural events")
            case .techMeetups: String(localized: "Technology meetups")
            case .followedOrganizers: String(localized: "From organizers you follow")
            }
        }
    }

    struct Section: Identifiable, Hashable, Sendable {
        var kind: SectionKind
        var events: [EventSummary]
        var id: SectionKind { kind }
    }

    /// Builds sections without repeating an event, so the feed reads as one clean list.
    static func sections(
        from events: [EventSummary],
        city: String?,
        preferredCategories: Set<String>,
        followedOrganizers: Set<UUID>,
        now: Date = .now,
        perSection: Int = 3
    ) -> [Section] {
        let upcoming = events.filter { !$0.hasEnded(now: now) && $0.status == .published }
            .sorted { $0.startsAt < $1.startsAt }
        var used = Set<UUID>()
        var result: [Section] = []

        func take(_ kind: SectionKind, limit: Int = perSection, _ predicate: (EventSummary) -> Bool) {
            let picked = upcoming.filter { !used.contains($0.id) && predicate($0) }.prefix(limit)
            guard !picked.isEmpty else { return }
            picked.forEach { used.insert($0.id) }
            result.append(Section(kind: kind, events: Array(picked)))
        }

        let week = DateRangeOption.thisWeek.interval(now: now)
        take(.recommended, limit: 2) { event in
            let near = city == nil || event.city == city || event.format != .physical
            return near && (preferredCategories.isEmpty || preferredCategories.contains(event.categoryID))
        }
        take(.followedOrganizers) { followedOrganizers.contains($0.organizerID) }
        take(.thisWeek) { event in week.map { event.startsAt < $0.end && event.endsAt > $0.start } ?? false }
        take(.hackathons) { $0.categoryID == "hackathons" }
        take(.free) { $0.isFree }
        take(.university) { $0.university != nil || $0.categoryID == "university" }
        take(.workshops) { $0.categoryID == "workshops" }
        take(.culture) { $0.categoryID == "culture" || $0.categoryID == "art" || $0.categoryID == "music" }
        take(.techMeetups) { $0.categoryID == "technology" }
        take(.upcoming, limit: .max) { _ in true }
        return result
    }
}
