import Foundation
import Network
import Observation

/// Publishes connectivity so screens can show offline states and the scanner can refuse
/// to admit attendees without server validation.
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "lk.zuno.network-monitor")

    init(start: Bool = true) {
        guard start else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
