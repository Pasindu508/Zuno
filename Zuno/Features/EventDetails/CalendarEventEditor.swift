import EventKit
import EventKitUI
import SwiftUI

/// "Add to Calendar" via the system event editor. Since iOS 17 the editor runs out of
/// process, so Zuno needs no calendar permission and never reads the user's calendars.
struct CalendarEventEditor: UIViewControllerRepresentable {
    let event: EventSummary
    let notes: String
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let calendarEvent = EKEvent(eventStore: store)
        calendarEvent.title = event.title
        calendarEvent.startDate = event.startsAt
        calendarEvent.endDate = event.endsAt
        calendarEvent.timeZone = .colombo
        calendarEvent.location = [event.venueName, event.city].compactMap { $0 }.joined(separator: ", ")
        calendarEvent.notes = notes
        calendarEvent.url = url
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = calendarEvent
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: { dismiss() }) }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: () -> Void
        init(dismiss: @escaping () -> Void) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}
