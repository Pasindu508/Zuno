import SwiftUI

/// Native dark filter sheet: charcoal controls, white selections, amber highlights,
/// a live result count, Apply and Clear All.
struct FilterSheet: View {
    let model: HomeModel
    let onApply: (EventFilters) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var draft = EventFilters()
    @State private var resultCount: Int?
    @State private var countTask: Task<Void, Never>?
    @State private var customFrom = Date.now
    @State private var customTo = Date.now.addingTimeInterval(7 * 86_400)
    @State private var distanceEnabled = false
    @State private var distance: Double = 25

    private let popularCities = ["Colombo", "Kandy", "Galle", "Jaffna", "Negombo", "Moratuwa", "Batticaloa", "Kurunegala"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section(Text("When")) {
                        FlowLayout(spacing: 8) {
                            ForEach(DateRangeOption.presets, id: \.self) { option in
                                SelectableChip(title: Text(option.title), isSelected: draft.dateRange == option) {
                                    draft.dateRange = option
                                }
                            }
                            SelectableChip(title: Text("Custom"), systemImage: "calendar", isSelected: isCustomDate) {
                                draft.dateRange = .custom(from: customFrom, to: customTo)
                            }
                        }
                        if isCustomDate {
                            VStack(spacing: 4) {
                                DatePicker("From", selection: $customFrom, displayedComponents: .date)
                                DatePicker("To", selection: $customTo, in: customFrom..., displayedComponents: .date)
                            }
                            .tint(ZunoColor.amber)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ZunoColor.surface))
                            .onChange(of: customFrom) { _, _ in draft.dateRange = .custom(from: customFrom, to: customTo) }
                            .onChange(of: customTo) { _, _ in draft.dateRange = .custom(from: customFrom, to: customTo) }
                        }
                    }

                    section(Text("Where")) {
                        FlowLayout(spacing: 8) {
                            ForEach(cityOptions, id: \.self) { city in
                                SelectableChip(title: Text(city), isSelected: draft.cities.contains(city)) {
                                    if draft.cities.contains(city) { draft.cities.remove(city) } else { draft.cities.insert(city) }
                                }
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(isOn: $distanceEnabled) {
                                Text("Within a distance of \(preferences.selectedCity)")
                                    .font(.body)
                            }
                            .tint(ZunoColor.amber)
                            if distanceEnabled {
                                HStack {
                                    Slider(value: $distance, in: 5...150, step: 5) { Text("Distance") }
                                        .tint(ZunoColor.amber)
                                    Text("\(Int(distance)) km")
                                        .font(.body.monospacedDigit())
                                        .frame(minWidth: 64, alignment: .trailing)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ZunoColor.surface))
                    }

                    section(Text("Price")) {
                        HStack(spacing: 8) {
                            ForEach(PriceFilter.allCases) { option in
                                SelectableChip(title: Text(option.title), isSelected: draft.price == option) { draft.price = option }
                            }
                        }
                    }

                    section(Text("Format")) {
                        HStack(spacing: 8) {
                            ForEach(FormatFilter.allCases) { option in
                                SelectableChip(title: Text(option.title), isSelected: draft.format == option) { draft.format = option }
                            }
                        }
                    }

                    section(Text("Availability")) {
                        Toggle(isOn: $draft.availableOnly) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Only events with places left")
                                Text("Hide sold-out events").font(.footnote).foregroundStyle(.zunoSecondary)
                            }
                        }
                        .tint(ZunoColor.amber)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(ZunoColor.surface))
                    }

                    if !organizers.isEmpty {
                        section(Text("Organizer")) {
                            FlowLayout(spacing: 8) {
                                ForEach(organizers, id: \.id) { organizer in
                                    SelectableChip(title: Text(organizer.name), isSelected: draft.organizerIDs.contains(organizer.id)) {
                                        if draft.organizerIDs.contains(organizer.id) { draft.organizerIDs.remove(organizer.id) }
                                        else { draft.organizerIDs.insert(organizer.id) }
                                    }
                                }
                            }
                        }
                    }

                    section(Text("Category")) {
                        FlowLayout(spacing: 8) {
                            ForEach(EventCategory.defaults) { category in
                                SelectableChip(title: Text(category.name), systemImage: category.symbolName,
                                               isSelected: draft.categoryIDs.contains(category.id)) {
                                    if draft.categoryIDs.contains(category.id) { draft.categoryIDs.remove(category.id) }
                                    else { draft.categoryIDs.insert(category.id) }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    HStack(spacing: 12) {
                        Button("Clear All") {
                            draft = EventFilters()
                            distanceEnabled = false
                        }
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                        .frame(maxWidth: 150)
                        .accessibilityIdentifier("filters.clear")
                        Button {
                            onApply(finalized)
                            dismiss()
                        } label: {
                            if let resultCount {
                                Text(resultCount == 1 ? "Show 1 event" : "Show \(resultCount) events")
                            } else {
                                Text("Apply Filters")
                            }
                        }
                        .buttonStyle(PrimaryCapsuleButtonStyle(compact: true))
                        .accessibilityIdentifier("filters.apply")
                    }
                }
            }
            .navigationTitle(Text("Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close filters"))
                }
            }
            .background(ZunoColor.background)
        }
        .presentationDetents([.large])
        .presentationCornerRadius(ZunoMetrics.sheetRadius)
        .presentationDragIndicator(.visible)
        .sensoryFeedback(.selection, trigger: draft)
        .onAppear {
            draft = model.filters
            if case .custom(let from, let to) = draft.dateRange { customFrom = from; customTo = to }
            distanceEnabled = draft.radiusKm != nil
            distance = draft.radiusKm ?? 25
            refreshCount()
        }
        .onChange(of: draft) { _, _ in refreshCount() }
        .onChange(of: distanceEnabled) { _, _ in refreshCount() }
        .onChange(of: distance) { _, _ in refreshCount() }
    }

    private var isCustomDate: Bool {
        if case .custom = draft.dateRange { return true }
        return false
    }

    private var cityOptions: [String] {
        var cities = popularCities
        if !cities.contains(preferences.selectedCity) { cities.insert(preferences.selectedCity, at: 0) }
        return cities
    }

    private var organizers: [(id: UUID, name: String)] {
        var seen = Set<UUID>()
        return (model.feed.value ?? []).compactMap { event in
            guard !seen.contains(event.organizerID), !event.organizerName.isEmpty else { return nil }
            seen.insert(event.organizerID)
            return (event.organizerID, event.organizerName)
        }.sorted { $0.name < $1.name }
    }

    private var finalized: EventFilters {
        var filters = draft
        if distanceEnabled, let place = SriLankaLocations.place(named: preferences.selectedCity) {
            filters.origin = place.location
            filters.radiusKm = distance
        } else {
            filters.origin = nil
            filters.radiusKm = nil
        }
        return filters
    }

    private func refreshCount() {
        countTask?.cancel()
        let filters = finalized
        countTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let count = await model.previewCount(for: filters, environment: environment)
            guard !Task.isCancelled else { return }
            resultCount = count
        }
    }

    private func section<Content: View>(_ title: Text, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            title
                .font(.headline)
                .foregroundStyle(.zunoPrimary)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}
