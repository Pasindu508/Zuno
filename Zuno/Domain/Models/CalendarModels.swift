import Foundation

struct CalendarItem: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable, Hashable { case registered, saved }

    var eventID: UUID
    var title: String
    var startsAt: Date
    var endsAt: Date
    var place: String
    var source: Source
    var cover: ImageReference?
    var id: String { "\(eventID.uuidString)-\(source.rawValue)" }
}

enum CalendarGrouping {
    struct DayCell: Identifiable, Hashable, Sendable {
        var date: Date
        var isInDisplayedMonth: Bool
        var id: Date { date }
    }

    /// Items keyed by the Colombo start-of-day of every day they span (multi-day events
    /// appear on each day, capped at 62 days so long exhibitions don't flood the grid).
    static func itemsByDay(_ items: [CalendarItem], calendar: Calendar = .colombo) -> [Date: [CalendarItem]] {
        var map: [Date: [CalendarItem]] = [:]
        for item in items {
            var day = calendar.startOfDay(for: item.startsAt)
            let lastDay = calendar.startOfDay(for: item.endsAt.addingTimeInterval(-1))
            var guardCount = 0
            while day <= lastDay && guardCount < 62 {
                map[day, default: []].append(item)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
                guardCount += 1
            }
        }
        for key in map.keys { map[key]?.sort { $0.startsAt < $1.startsAt } }
        return map
    }

    /// A Monday-first 6×7 grid for the month containing `month`.
    static func monthGrid(for month: Date, calendar: Calendar = .colombo) -> [DayCell] {
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: interval.start)!
        return (0..<42).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: gridStart)!
            // DateInterval.contains is end-inclusive; the month is half-open.
            return DayCell(date: date, isInDisplayedMonth: date >= interval.start && date < interval.end)
        }
    }

    /// Agenda: upcoming items grouped by day in chronological order.
    static func agenda(_ items: [CalendarItem], from now: Date, calendar: Calendar = .colombo) -> [(day: Date, items: [CalendarItem])] {
        let upcoming = items.filter { $0.endsAt >= now }
        let grouped = Dictionary(grouping: upcoming) { calendar.startOfDay(for: max($0.startsAt, calendar.startOfDay(for: now))) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.startsAt < $1.startsAt }) }
    }
}
