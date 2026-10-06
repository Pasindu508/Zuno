import CoreLocation
import SwiftUI

/// Choose a city, or opt in to the current location after an explanation.
struct LocationPickerSheet: View {
    let selectedCity: String
    let onSelect: (SriLankaLocations.Place) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var locator = OneShotLocator()
    @State private var locating = false
    @State private var locationMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        HStack {
                            Label("Use my current location", systemImage: "location.fill")
                                .foregroundStyle(.zunoPrimary)
                            Spacer()
                            if locating { ProgressView() }
                        }
                    }
                    .disabled(locating)
                } footer: {
                    Text(locationMessage ?? String(localized: "Zuno only uses your location to find the nearest city. It isn't stored or shared."))
                }
                .listRowBackground(ZunoColor.surface)

                ForEach(provinces, id: \.self) { province in
                    Section(province) {
                        ForEach(filtered.filter { $0.province == province }) { place in
                            Button {
                                onSelect(place)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(place.city).foregroundStyle(.zunoPrimary)
                                        Text("\(place.district) District").font(.footnote).foregroundStyle(.zunoSecondary)
                                    }
                                    Spacer()
                                    if place.city == selectedCity {
                                        Image(systemName: "checkmark").foregroundStyle(.zunoAmber)
                                    }
                                }
                            }
                            .accessibilityAddTraits(place.city == selectedCity ? .isSelected : [])
                        }
                    }
                    .listRowBackground(ZunoColor.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ZunoColor.background)
            .searchable(text: $query, prompt: Text("Search cities and districts"))
            .navigationTitle(Text("Location"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(Text("Close"))
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filtered: [SriLankaLocations.Place] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return SriLankaLocations.places }
        return SriLankaLocations.places.filter {
            $0.city.localizedCaseInsensitiveContains(trimmed) || $0.district.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var provinces: [String] {
        var seen: [String] = []
        for place in filtered where !seen.contains(place.province) { seen.append(place.province) }
        return seen
    }

    private func useCurrentLocation() async {
        locating = true
        defer { locating = false }
        switch await locator.locate() {
        case .success(let point):
            onSelect(SriLankaLocations.nearest(to: point))
            dismiss()
        case .failure(let message):
            locationMessage = message
        }
    }
}

/// Requests when-in-use permission only when the user taps "Use my current location".
@MainActor
final class OneShotLocator: NSObject, CLLocationManagerDelegate {
    enum Outcome { case success(GeoPoint), failure(String) }

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Outcome, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func locate() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: finish(.failure(String(localized: "Location access is off. Choose a city below, or allow location for Zuno in Settings.")))
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard continuation != nil else { return }
            switch status {
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            case .denied, .restricted: finish(.failure(String(localized: "Location access is off. Choose a city below.")))
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let point = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        MainActor.assumeIsolated { finish(.success(point)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { finish(.failure(String(localized: "We couldn't find your location. Choose a city below."))) }
    }
}
