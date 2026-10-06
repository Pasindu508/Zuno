import Foundation
import Observation

@MainActor
@Observable
final class HomeModel {
    var feed: Loadable<[EventSummary]> = .idle
    var categories: [CategoryOption] = [.forYou] + EventCategory.defaults.map(CategoryOption.init)
    var selectedCategory = CategoryOption.forYouID
    var savedIDs: Set<UUID> = []
    var followedOrganizers: Set<UUID> = []
    var unreadCount = 0
    var filters = EventFilters()

    var query = ""
    var isSearchActive = false
    var searchResults: Loadable<[EventSummary]> = .idle
    var lastError: String?

    private var searchTask: Task<Void, Never>?
    private var realtimeTask: Task<Void, Never>?
    private var lastLoaded: Date?

    // MARK: Loading

    func loadIfNeeded(environment: AppEnvironment, session: SessionStore) async {
        if case .loaded = feed, let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 120 { return }
        await load(environment: environment, session: session)
    }

    func load(environment: AppEnvironment, session: SessionStore) async {
        if feed.value == nil { feed = .loading }
        async let categoriesTask = try? environment.events.categories()
        do {
            let events = try await environment.events.searchEvents(query: nil, filters: filters, limit: 120)
            feed = .loaded(events)
            lastLoaded = .now
            let references = events.prefix(4).compactMap(\.cover)
            await ImagePipeline.shared.prefetch(references, maxPixelSize: 1200)
        } catch {
            if feed.value == nil { feed = .failed(error) } else { lastError = error.localizedDescription }
        }
        if let categories = await categoriesTask, !categories.isEmpty {
            self.categories = [.forYou] + categories.sorted { $0.sortOrder < $1.sortOrder }.map(CategoryOption.init)
        }
        await loadPersonalState(environment: environment, session: session)
    }

    func loadPersonalState(environment: AppEnvironment, session: SessionStore) async {
        guard session.isSignedIn else {
            savedIDs = []
            followedOrganizers = []
            unreadCount = 0
            return
        }
        savedIDs = (try? await environment.events.savedEventIDs()) ?? savedIDs
        followedOrganizers = (try? await environment.events.followedOrganizerIDs()) ?? followedOrganizers
        await refreshUnread(environment: environment)
        startRealtime(environment: environment)
    }

    func refreshUnread(environment: AppEnvironment) async {
        let notifications = (try? await environment.notifications.notifications()) ?? []
        unreadCount = notifications.filter(\.isUnread).count
    }

    private func startRealtime(environment: AppEnvironment) {
        guard realtimeTask == nil else { return }
        realtimeTask = Task { [weak self] in
            let stream = await environment.notifications.changes()
            for await _ in stream {
                await self?.refreshUnread(environment: environment)
            }
        }
    }

    func stopRealtime() {
        realtimeTask?.cancel()
        realtimeTask = nil
    }

    // MARK: Derived content

    func sections(city: String?, preferred: Set<String>, now: Date) -> [HomeFeed.Section] {
        HomeFeed.sections(from: feed.value ?? [], city: city, preferredCategories: preferred,
                          followedOrganizers: followedOrganizers, now: now)
    }

    func categoryEvents(now: Date) -> [EventSummary] {
        (feed.value ?? []).filter { $0.categoryID == selectedCategory && !$0.hasEnded(now: now) }
            .sorted { $0.startsAt < $1.startsAt }
    }

    // MARK: Actions

    func toggleSave(_ event: EventSummary, environment: AppEnvironment, session: SessionStore) {
        guard session.isSignedIn else {
            session.requireAccount(for: .saveEvent(eventID: event.id))
            return
        }
        let shouldSave = !savedIDs.contains(event.id)
        if shouldSave { savedIDs.insert(event.id) } else { savedIDs.remove(event.id) }
        Task {
            do {
                try await environment.events.setSaved(shouldSave, eventID: event.id)
            } catch {
                // Roll back the optimistic change.
                if shouldSave { savedIDs.remove(event.id) } else { savedIDs.insert(event.id) }
                lastError = (error as? LocalizedError)?.errorDescription
            }
        }
    }

    func searchTextChanged(environment: AppEnvironment) {
        searchTask?.cancel()
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty || !filters.isEmpty else {
            searchResults = .idle
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await runSearch(text: text, environment: environment)
        }
    }

    func submitSearch(environment: AppEnvironment) {
        environment.preferences.addRecentSearch(query)
        searchTask?.cancel()
        searchTask = Task { await runSearch(text: query, environment: environment) }
    }

    private func runSearch(text: String, environment: AppEnvironment) async {
        searchResults = .loading
        do {
            let results = try await environment.events.searchEvents(query: text, filters: filters, limit: 80)
            guard !Task.isCancelled else { return }
            searchResults = .loaded(results)
        } catch is CancellationError {
        } catch {
            searchResults = .failed(error)
        }
    }

    func applyFilters(_ newFilters: EventFilters, environment: AppEnvironment, session: SessionStore) async {
        filters = newFilters
        if isSearchActive || !query.isEmpty {
            await runSearch(text: query, environment: environment)
        } else {
            feed = .loading
            await load(environment: environment, session: session)
        }
    }

    /// Result count preview for the filter sheet.
    func previewCount(for draft: EventFilters, environment: AppEnvironment) async -> Int? {
        try? await environment.events.searchEvents(query: query.isEmpty ? nil : query, filters: draft, limit: 200).count
    }
}
