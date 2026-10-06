import Observation
import SwiftUI

@MainActor
@Observable
final class CalendarModel {
    var items: [CalendarItem] = []
    var state: Loadable<Void> = .idle
    var showRegistered = true
    var showSaved = true

    func load(environment: AppEnvironment, isSignedIn: Bool) async {
        guard isSignedIn else { items = []; state = .loaded(()); return }
        if items.isEmpty { state = .loading }
        do {
            async let ticketsTask = environment.tickets.tickets()
            async let savedTask = environment.events.savedEvents()
            let (tickets, saved) = try await (ticketsTask, savedTask)
            var seen = Set<UUID>()
            var result: [CalendarItem] = []
            for ticket in tickets where ticket.status != .cancelled && ticket.status != .refunded && !seen.contains(ticket.event.id) {
                seen.insert(ticket.event.id)
                result.append(CalendarItem(eventID: ticket.event.id, title: ticket.event.title, startsAt: ticket.event.startsAt,
                                           endsAt: ticket.event.endsAt, place: ticket.event.venueName ?? String(localized: "Online"),
                                           source: .registered, cover: ticket.event.cover))
            }
            for event in saved where !seen.contains(event.id) {
                result.append(CalendarItem(eventID: event.id, title: event.title, startsAt: event.startsAt, endsAt: event.endsAt,
                                           place: event.placeLine, source: .saved, cover: event.cover))
            }
            items = result
            state = .loaded(())
        } catch {
            if items.isEmpty { state = .failed(error) }
        }
    }

    var visibleItems: [CalendarItem] {
        items.filter { ($0.source == .registered && showRegistered) || ($0.source == .saved && showSaved) }
    }
}

struct CalendarTabRoot: View {
    @Environment(AppRouter.self) private var router
    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.calendarPath) {
            CalendarView()
                .navigationDestination(for: AppRoute.self) { AppDestination(route: $0, namespace: nil) }
        }
    }
}

struct CalendarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case month, agenda
        var id: String { rawValue }
        var title: String { self == .month ? String(localized: "Month") : String(localized: "Agenda") }
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = CalendarModel()
    @State private var mode: Mode = .month
    @State private var month = Date.now
    @State private var selectedDay = Calendar.colombo.startOfDay(for: .now)
    @State private var exportItem: CalendarItem?
    @State private var initialized = false

    var body: some View {
        Group {
            if !session.isSignedIn {
                SignInPromptView(title: Text("Plan your month"),
                                 message: Text("Sign in to see the events you've registered for and saved, by day."))
            } else {
                content
            }
        }
        .background(ZunoColor.background)
        .navigationTitle(Text("Calendar"))
        .task(id: session.user?.id) {
            if !initialized {
                month = environment.now
                selectedDay = Calendar.colombo.startOfDay(for: environment.now)
                initialized = true
            }
            await model.load(environment: environment, isSignedIn: session.isSignedIn)
        }
        .refreshable { await model.load(environment: environment, isSignedIn: session.isSignedIn) }
        .sheet(item: $exportItem) { item in
            CalendarEventEditor(event: placeholderSummary(item), notes: "", url: URL(string: "https://zuno.lk/e/\(item.eventID.uuidString.lowercased())")!)
                .ignoresSafeArea()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker(selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                } label: { Text("Calendar view") }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("calendar.mode")

                HStack(spacing: 8) {
                    SelectableChip(title: Text("Registered"), systemImage: "ticket", isSelected: model.showRegistered) { model.showRegistered.toggle() }
                    SelectableChip(title: Text("Saved"), systemImage: "heart", isSelected: model.showSaved) { model.showSaved.toggle() }
                }

                switch model.state {
                case .idle, .loading:
                    ShimmerPlaceholder().frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 22))
                case .failed(let error):
                    ErrorStateView(error: error) { Task { await model.load(environment: environment, isSignedIn: true) } }.frame(minHeight: 300)
                case .loaded:
                    if mode == .month {
                        if horizontalSizeClass == .regular {
                            HStack(alignment: .top, spacing: 24) {
                                monthGrid.frame(maxWidth: 460)
                                dayList
                            }
                        } else {
                            monthGrid
                            dayList
                        }
                    } else {
                        agenda
                    }
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
            .padding(.bottom, 24)
            .readableWidth(horizontalSizeClass == .regular ? 1000 : .infinity)
        }
    }

    private var itemsByDay: [Date: [CalendarItem]] { CalendarGrouping.itemsByDay(model.visibleItems) }

    private var monthGrid: some View {
        let cells = CalendarGrouping.monthGrid(for: month)
        let map = itemsByDay
        let today = Calendar.colombo.startOfDay(for: environment.now)
        return VStack(spacing: 12) {
            HStack {
                Text(ZunoFormat.monthYear(month))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.zunoPrimary)
                    .contentTransition(.numericText())
                Spacer()
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        FloatingGlassIconButton(systemName: "chevron.left", accessibilityLabel: Text("Previous month")) { shiftMonth(-1) }
                        FloatingGlassIconButton(systemName: "chevron.right", accessibilityLabel: Text("Next month")) { shiftMonth(1) }
                    }
                }
                .scaleEffect(0.82)
            }
            let symbols = Calendar.colombo.veryShortStandaloneWeekdaySymbols
            let ordered = Array(symbols[1...]) + [symbols[0]] // Monday first
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption.weight(.semibold)).foregroundStyle(.zunoTertiary).frame(maxWidth: .infinity)
                        .accessibilityHidden(true)
                }
                ForEach(cells) { cell in
                    DayCellView(cell: cell, items: map[cell.date] ?? [], isSelected: cell.date == selectedDay, isToday: cell.date == today) {
                        selectedDay = cell.date
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selectedDay)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(ZunoColor.surface))
        .zunoContainer("calendar.month")
    }

    private var dayList: some View {
        let items = itemsByDay[selectedDay] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            Text(ZunoFormat.longDay(selectedDay)).font(.headline).foregroundStyle(.zunoPrimary)
            if items.isEmpty {
                Text("Nothing planned for this day.").font(.callout).foregroundStyle(.zunoSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(items) { item in row(item) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agenda: some View {
        let groups = CalendarGrouping.agenda(model.visibleItems, from: environment.now)
        return VStack(alignment: .leading, spacing: 20) {
            if groups.isEmpty {
                EmptyStateView(symbol: "calendar", title: Text("Nothing coming up"),
                               message: Text("Register for or save events and they'll appear in your agenda."))
                    .frame(minHeight: 300)
            }
            ForEach(groups, id: \.day) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(ZunoFormat.longDay(group.day)).font(.headline).foregroundStyle(.zunoPrimary)
                    ForEach(group.items) { row($0) }
                }
            }
        }
        .zunoContainer("calendar.agenda")
    }

    private func row(_ item: CalendarItem) -> some View {
        NavigationLink(value: AppRoute.event(item.eventID)) {
            HStack(spacing: 12) {
                ArtworkImage(reference: item.cover)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).zunoDisplay(.compact).foregroundStyle(.zunoPrimary).lineLimit(1)
                    Text("\(ZunoFormat.time(item.startsAt)) · \(item.place)").font(.footnote).foregroundStyle(.zunoSecondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: item.source == .registered ? "ticket.fill" : "heart.fill")
                    .foregroundStyle(item.source == .registered ? ZunoColor.textPrimary : ZunoColor.amber)
                    .accessibilityLabel(item.source == .registered ? Text("Registered") : Text("Saved"))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ZunoColor.surface))
        }
        .buttonStyle(CardPressStyle())
        .contextMenu {
            Button { exportItem = item } label: { Label("Add to Calendar", systemImage: "calendar.badge.plus") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Add to Calendar")) { exportItem = item }
    }

    private func shiftMonth(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            month = Calendar.colombo.date(byAdding: .month, value: delta, to: month) ?? month
        }
    }

    private func placeholderSummary(_ item: CalendarItem) -> EventSummary {
        EventSummary(id: item.eventID, title: item.title, summary: "", categoryID: "community", categoryName: "", organizerID: UUID(),
                     organizerName: "", venueName: item.place, city: nil, district: nil, location: nil, university: nil, format: .physical,
                     startsAt: item.startsAt, endsAt: item.endsAt, isFree: true, minPrice: nil, capacity: 1, seatsRemaining: 1,
                     cover: item.cover, coverAlt: nil, tags: [], status: .published)
    }
}

private struct DayCellView: View {
    let cell: CalendarGrouping.DayCell
    let items: [CalendarItem]
    let isSelected: Bool
    let isToday: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text("\(Calendar.colombo.component(.day, from: cell.date))")
                    .font(.callout.weight(isSelected || isToday ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? ZunoColor.onSelectedFill : (cell.isInDisplayedMonth ? ZunoColor.textPrimary : ZunoColor.textTertiary))
                    .frame(width: 36, height: 36)
                    .background {
                        if isSelected { Circle().fill(ZunoColor.selectedFill) }
                        else if isToday { Circle().strokeBorder(ZunoColor.amber, lineWidth: 1.5) }
                    }
                HStack(spacing: 3) {
                    if items.contains(where: { $0.source == .registered }) {
                        Circle().fill(ZunoColor.textPrimary).frame(width: 5, height: 5)
                    }
                    if items.contains(where: { $0.source == .saved }) {
                        Circle().strokeBorder(ZunoColor.amber, lineWidth: 1.2).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 46)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityText: String {
        let day = ZunoFormat.longDay(cell.date)
        if items.isEmpty { return day }
        return String(AttributedString(localized: "\(day), ^[\(items.count) event](inflect: true)").characters)
    }
}
