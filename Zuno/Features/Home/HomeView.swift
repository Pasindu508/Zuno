import SwiftUI

struct HomeTabRoot: View {
    @Environment(AppRouter.self) private var router
    @Namespace private var zoomNamespace

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.homePath) {
            HomeView(zoomNamespace: zoomNamespace)
                .navigationDestination(for: AppRoute.self) { route in
                    AppDestination(route: route, namespace: zoomNamespace)
                }
        }
    }
}

struct HomeView: View {
    let zoomNamespace: Namespace.ID

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionStore.self) private var session
    @Environment(AppRouter.self) private var router
    @Environment(AppPreferences.self) private var preferences
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = HomeModel()
    @State private var showFilters = false
    @State private var showLocationPicker = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LocationHeader(
                    city: preferences.selectedCity,
                    unreadCount: model.unreadCount,
                    onLocationTap: { showLocationPicker = true },
                    onNotificationsTap: openNotifications
                )
                .padding(.horizontal, ZunoMetrics.margin)
                .padding(.top, 6)

                HomeSearchBar(
                    text: $model.query,
                    isFocused: $searchFocused,
                    isActive: model.isSearchActive,
                    activeFilterCount: model.filters.activeCount,
                    onFilter: { showFilters = true },
                    onCancel: closeSearch
                )
                .padding(.horizontal, ZunoMetrics.margin)
                .padding(.top, ZunoMetrics.headerToSearch)

                if !network.isOnline {
                    OfflineBanner()
                        .padding(.horizontal, ZunoMetrics.margin)
                        .padding(.top, 12)
                }

                if model.isSearchActive {
                    SearchResultsView(model: model, zoomNamespace: zoomNamespace, now: environment.now)
                        .padding(.top, 20)
                        .transition(.opacity)
                } else {
                    CategoryBar(options: model.categories, selection: $model.selectedCategory)
                        .padding(.top, ZunoMetrics.searchToChips)
                    feedContent
                        .padding(.top, ZunoMetrics.chipsToFeed)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 32)
            .readableWidth(horizontalSizeClass == .regular ? 1100 : .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(alignment: .top) { HomeBackdrop() }
        .background(ZunoColor.background)
        .toolbarVisibility(.hidden, for: .navigationBar)
        .refreshable { await model.load(environment: environment, session: session) }
        .task { await model.loadIfNeeded(environment: environment, session: session) }
        .onChange(of: session.isSignedIn) { _, _ in
            Task { await model.loadPersonalState(environment: environment, session: session) }
        }
        .onChange(of: searchFocused) { _, focused in
            if focused && !model.isSearchActive {
                withAnimation(ZunoMotion.adaptive(ZunoMotion.expand, reduceMotion: reduceMotion)) { model.isSearchActive = true }
            }
        }
        .onChange(of: model.query) { _, _ in model.searchTextChanged(environment: environment) }
        .onSubmit(of: .search) { model.submitSearch(environment: environment) }
        .sheet(isPresented: $showFilters) {
            FilterSheet(model: model) { filters in
                Task { await model.applyFilters(filters, environment: environment, session: session) }
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet(selectedCity: preferences.selectedCity) { place in
                preferences.selectedCity = place.city
            }
        }
        .onDisappear { model.stopRealtime() }
    }

    @ViewBuilder
    private var feedContent: some View {
        switch model.feed {
        case .idle, .loading:
            LoadingFeedView()
                .padding(.horizontal, ZunoMetrics.margin)
        case .failed(let error):
            ErrorStateView(error: error) {
                Task { await model.load(environment: environment, session: session) }
            }
            .frame(minHeight: 360)
        case .loaded:
            if model.selectedCategory == CategoryOption.forYouID {
                forYouFeed
            } else {
                categoryFeed
            }
        }
    }

    private var forYouFeed: some View {
        let sections = model.sections(city: preferences.selectedCity,
                                      preferred: Set(session.profile?.preferredCategories ?? []),
                                      now: environment.now)
        return VStack(alignment: .leading, spacing: 30) {
            if sections.isEmpty {
                EmptyStateView(symbol: "calendar", title: Text("No upcoming events yet"),
                               message: Text("New events in Sri Lanka will appear here as organizers publish them."))
                    .frame(minHeight: 320)
            }
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                VStack(alignment: .leading, spacing: 14) {
                    if index > 0 || sections.count > 1 {
                        SectionHeader(title: Text(section.kind.title))
                            .padding(.horizontal, ZunoMetrics.margin)
                    }
                    cards(section.events)
                }
                .zunoContainer("home.section.\(section.kind.rawValue)")
            }
        }
    }

    private var categoryFeed: some View {
        let events = model.categoryEvents(now: environment.now)
        return Group {
            if events.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: Text("Nothing here yet"),
                               message: Text("There are no upcoming events in this category. Try another category or check back soon."))
                    .frame(minHeight: 320)
            } else {
                cards(events)
            }
        }
    }

    @ViewBuilder
    private func cards(_ events: [EventSummary]) -> some View {
        if horizontalSizeClass == .regular {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 520), spacing: 18, alignment: .top)], spacing: 18) {
                ForEach(events) { card($0) }
            }
            .padding(.horizontal, ZunoMetrics.margin + 6)
        } else {
            LazyVStack(spacing: ZunoMetrics.cardSpacing) {
                ForEach(events) { card($0) }
            }
            .padding(.horizontal, ZunoMetrics.margin)
        }
    }

    private func card(_ event: EventSummary) -> some View {
        EventCardLink(event: event, isSaved: model.savedIDs.contains(event.id), namespace: zoomNamespace, now: environment.now) {
            model.toggleSave(event, environment: environment, session: session)
        }
    }

    private func openNotifications() {
        if session.isSignedIn {
            router.open(.notifications, in: .home)
        } else {
            session.requireAccount(for: .openTab(.home))
        }
    }

    private func closeSearch() {
        searchFocused = false
        withAnimation(ZunoMotion.adaptive(ZunoMotion.expand, reduceMotion: reduceMotion)) {
            model.isSearchActive = false
            model.query = ""
        }
        model.searchResults = .idle
    }
}

/// A barely-there warm glow under the status bar, echoing the reference's lit top edge.
struct HomeBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [ZunoColor.amber.opacity(0.07), ZunoColor.background.opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: 260)
        .ignoresSafeArea(edges: .top)
        .accessibilityHidden(true)
    }
}
