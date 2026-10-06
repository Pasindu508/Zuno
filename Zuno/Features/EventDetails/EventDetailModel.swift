import Foundation
import Observation

@MainActor
@Observable
final class EventDetailModel {
    enum Sheet: String, Identifiable {
        case registerFree, checkout, addToCalendar
        var id: String { rawValue }
    }

    var detail: Loadable<EventDetail> = .idle
    var related: [EventSummary] = []
    var isSaved = false
    var isFollowingOrganizer = false
    var sheet: Sheet?
    var banner: String?
    var isWorking = false
    var waitlistJoined = false

    func load(eventID: UUID, environment: AppEnvironment) async {
        if detail.value == nil { detail = .loading }
        do {
            let loaded = try await environment.events.eventDetail(id: eventID)
            detail = .loaded(loaded)
            isSaved = loaded.viewer.isSaved
            let followed = (try? await environment.events.followedOrganizerIDs()) ?? []
            isFollowingOrganizer = followed.contains(loaded.summary.organizerID)
            await loadRelated(for: loaded.summary, environment: environment)
        } catch {
            if detail.value == nil { detail = .failed(error) } else { banner = error.localizedDescription }
        }
    }

    private func loadRelated(for event: EventSummary, environment: AppEnvironment) async {
        var filters = EventFilters()
        filters.categoryIDs = [event.categoryID]
        let sameCategory = (try? await environment.events.searchEvents(query: nil, filters: filters, limit: 8)) ?? []
        related = Array(sameCategory.filter { $0.id != event.id }.prefix(4))
    }

    func toggleSave(environment: AppEnvironment, session: SessionStore) {
        guard let event = detail.value?.summary else { return }
        guard session.isSignedIn else {
            session.requireAccount(for: .saveEvent(eventID: event.id))
            return
        }
        let target = !isSaved
        isSaved = target
        Task {
            do { try await environment.events.setSaved(target, eventID: event.id) } catch {
                isSaved = !target
                banner = (error as? LocalizedError)?.errorDescription
            }
        }
    }

    func toggleFollow(environment: AppEnvironment, session: SessionStore) {
        guard let event = detail.value?.summary else { return }
        guard session.isSignedIn else {
            session.requireAccount(for: .openTab(.home))
            return
        }
        let target = !isFollowingOrganizer
        isFollowingOrganizer = target
        Task {
            do { try await environment.events.setFollowing(target, organizerID: event.organizerID) } catch {
                isFollowingOrganizer = !target
            }
        }
    }

    func joinWaitlist(environment: AppEnvironment) async {
        guard let event = detail.value?.summary else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let confirmation = try await environment.registrations.joinWaitlist(eventID: event.id)
            waitlistJoined = true
            banner = String(localized: "You're number \(confirmation.position) on the waitlist. We'll notify you if a place opens.")
            await load(eventID: event.id, environment: environment)
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func cancelRegistration(environment: AppEnvironment) async {
        guard let current = detail.value, let registrationID = current.viewer.registrationID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.registrations.cancelRegistration(id: registrationID)
            banner = String(localized: "Your registration was cancelled.")
            await load(eventID: current.id, environment: environment)
        } catch {
            banner = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func registrationCompleted(environment: AppEnvironment) async {
        guard let id = detail.value?.id else { return }
        await load(eventID: id, environment: environment)
    }
}
