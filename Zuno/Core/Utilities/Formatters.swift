import Foundation

/// Sri Lankan formatting: LKR amounts, Asia/Colombo dates and times.
enum ZunoFormat {
    // MARK: Currency

    private static let groupingLocale = Locale(identifier: "en_LK")

    /// "LKR 1,500.00". `compact` drops ".00" on whole amounts ("LKR 1,500").
    /// Negative amounts render as "−LKR 2.50" with a true minus sign.
    static func currency(_ money: Money, compact: Bool = false, showSign: Bool = false) -> String {
        let magnitude = abs(money.minorUnits)
        let whole = magnitude / 100
        let cents = magnitude % 100
        let formatter = NumberFormatter()
        formatter.locale = groupingLocale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = 0
        let wholeText = formatter.string(from: NSNumber(value: whole)) ?? "\(whole)"
        let fraction = (compact && cents == 0) ? "" : String(format: ".%02lld", cents)
        let code = money.currency == "LKR" ? "LKR" : money.currency
        let sign: String = if money.minorUnits < 0 { "\u{2212}" } else if showSign && money.minorUnits > 0 { "+" } else { "" }
        return "\(sign)\(code) \(wholeText)\(fraction)"
    }

    /// PayHere expects plain two-decimal amounts without grouping ("1500.00").
    static func gatewayAmount(_ money: Money) -> String {
        String(format: "%lld.%02lld", money.minorUnits / 100, abs(money.minorUnits % 100))
    }

    static func priceLabel(for event: EventSummary) -> String {
        if event.isFree { return String(localized: "Free") }
        guard let price = event.minPrice else { return String(localized: "Paid") }
        return currency(price, compact: true)
    }

    // MARK: Dates

    /// Sri Lankan locale in the app's active language (en_LK, si_LK or ta_LK).
    static var locale: Locale {
        switch Bundle.main.preferredLocalizations.first {
        case "si"?: Locale(identifier: "si_LK")
        case "ta"?: Locale(identifier: "ta_LK")
        default: Locale(identifier: "en_LK")
        }
    }

    private static func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
        var style = base
        style.timeZone = .colombo
        style.locale = locale
        style.calendar = .colombo
        return style
    }

    /// "16 Oct" / "16 Oct 2027" when not in the current year.
    static func dayMonth(_ date: Date, now: Date = .now) -> String {
        let sameYear = Calendar.colombo.component(.year, from: date) == Calendar.colombo.component(.year, from: now)
        let base = Date.FormatStyle().day().month(.abbreviated)
        return date.formatted(style(sameYear ? base : base.year()))
    }

    /// "6:30 PM" in Colombo time.
    static func time(_ date: Date) -> String {
        date.formatted(style(Date.FormatStyle().hour().minute()))
    }

    /// "Sat, 12 Oct".
    static func weekdayDayMonth(_ date: Date) -> String {
        date.formatted(style(Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)))
    }

    /// "Saturday 12 October".
    static func longDay(_ date: Date) -> String {
        date.formatted(style(Date.FormatStyle().weekday(.wide).day().month(.wide)))
    }

    /// "October 2026".
    static func monthYear(_ date: Date) -> String {
        date.formatted(style(Date.FormatStyle().month(.wide).year()))
    }

    /// Card metadata: "16 Oct – 3 Nov" for multi-day, "Sat, 12 Oct · 6:30 PM" otherwise.
    static func eventDateLine(start: Date, end: Date, now: Date = .now) -> String {
        let calendar = Calendar.colombo
        if calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) || end.timeIntervalSince(start) <= 12 * 3600 {
            return "\(weekdayDayMonth(start)) · \(time(start))"
        }
        return "\(dayMonth(start, now: now)) – \(dayMonth(end, now: now))"
    }

    /// Detail page time line: "6:30 PM – 9:30 PM" or "Sat 12 Oct, 8:30 AM – Sun 13 Oct, 8:30 PM".
    static func timeRange(start: Date, end: Date) -> String {
        if Calendar.colombo.isDate(start, inSameDayAs: end) {
            return "\(time(start)) – \(time(end))"
        }
        return "\(weekdayDayMonth(start)), \(time(start)) – \(weekdayDayMonth(end)), \(time(end))"
    }

    /// Text for the glass pill over artwork, e.g. "Until 5 Nov", "Today, 6:30 PM", "Sat, 12 Oct".
    static func pillText(for event: EventSummary, now: Date = .now) -> String {
        if event.status == .cancelled { return String(localized: "Cancelled") }
        if event.hasEnded(now: now) { return String(localized: "Ended") }
        if event.isOngoing(now: now) && event.isMultiDay {
            return String(localized: "Until \(dayMonth(event.endsAt, now: now))")
        }
        if Calendar.colombo.isDate(event.startsAt, inSameDayAs: now) {
            return String(localized: "Today, \(time(event.startsAt))")
        }
        let tomorrow = Calendar.colombo.date(byAdding: .day, value: 1, to: now)!
        if Calendar.colombo.isDate(event.startsAt, inSameDayAs: tomorrow) {
            return String(localized: "Tomorrow, \(time(event.startsAt))")
        }
        return weekdayDayMonth(event.startsAt)
    }

    /// Compact ISO date for SF Mono contexts: "2026-10-12 18:30".
    static func compactTimestamp(_ date: Date) -> String {
        var style = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeZone: .colombo)
        style = style.year().month().day().time(includingFractionalSeconds: false)
        return String(date.formatted(style).prefix(16))
    }

    static func relative(_ date: Date, now: Date = .now) -> String {
        let style = Date.RelativeFormatStyle(presentation: .named, unitsStyle: .abbreviated, locale: locale, calendar: .colombo)
        return date.formatted(style)
    }
}
