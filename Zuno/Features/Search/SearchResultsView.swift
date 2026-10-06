import SwiftUI

/// Inline search results under the active search field, with recent searches and
/// suggestions when the query is empty.
struct SearchResultsView: View {
    @Bindable var model: HomeModel
    let zoomNamespace: Namespace.ID
    let now: Date

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let suggestions = ["Hackathon", "Colombo", "This weekend", "Free", "University of Moratuwa", "Music", "Workshop", "Online"]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.query.trimmingCharacters(in: .whitespaces).isEmpty && model.filters.isEmpty {
                idleContent
            } else {
                switch model.searchResults {
                case .idle, .loading:
                    LoadingFeedView(count: 1)
                        .padding(.horizontal, ZunoMetrics.margin)
                case .failed(let error):
                    ErrorStateView(error: error) { model.submitSearch(environment: environment) }
                        .frame(minHeight: 300)
                case .loaded(let results):
                    resultsList(results)
                }
            }
        }
        .zunoContainer("search.results")
    }

    @ViewBuilder
    private var idleContent: some View {
        if !preferences.recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: Text("Recent"), actionTitle: Text("Clear"), action: { preferences.recentSearches = [] })
                ForEach(preferences.recentSearches, id: \.self) { recent in
                    Button {
                        model.query = recent
                        model.submitSearch(environment: environment)
                    } label: {
                        Label(recent, systemImage: "clock")
                            .font(.body)
                            .foregroundStyle(.zunoPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
        }
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: Text("Try searching for"))
            FlowLayout(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    SelectableChip(title: Text(suggestion), isSelected: false) {
                        model.query = suggestion
                        model.submitSearch(environment: environment)
                    }
                }
            }
        }
        .padding(.horizontal, ZunoMetrics.margin)
    }

    @ViewBuilder
    private func resultsList(_ results: [EventSummary]) -> some View {
        Text(results.count == 1 ? "1 event" : "\(results.count) events")
            .font(.subheadline)
            .foregroundStyle(.zunoSecondary)
            .padding(.horizontal, ZunoMetrics.margin)
            .accessibilityIdentifier("search.count")
        if results.isEmpty {
            EmptyStateView(symbol: "magnifyingglass", title: Text("No matching events"),
                           message: Text("Try a different word, a nearby city, or clear some filters."))
                .frame(minHeight: 280)
        } else {
            let columns = horizontalSizeClass == .regular
                ? [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 18, alignment: .top)]
                : [GridItem(.flexible())]
            LazyVGrid(columns: columns, spacing: ZunoMetrics.cardSpacing) {
                ForEach(results) { event in
                    EventCardLink(event: event, isSaved: model.savedIDs.contains(event.id), namespace: zoomNamespace, now: now) {
                        model.toggleSave(event, environment: environment, session: session)
                    }
                }
            }
            .padding(.horizontal, ZunoMetrics.margin)
        }
    }
}

/// Wrapping layout for chips (search suggestions, preferences, filters).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
