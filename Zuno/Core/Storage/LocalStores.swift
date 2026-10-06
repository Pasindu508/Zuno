import Foundation
import Observation

/// Writes small JSON documents to Application Support with complete file protection.
/// Used for offline-safe data the user already owns (issued tickets).
struct SecureFileStore: Sendable {
    let directoryName: String

    static let standard = SecureFileStore(directoryName: "ZunoSecure")

    private var directory: URL {
        get throws {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            var url = base.appendingPathComponent(directoryName, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try url.setResourceValues(values)
            }
            return url
        }
    }

    func write<T: Encodable>(_ value: T, to name: String) throws {
        let data = try JSONEncoder.zuno.encode(value)
        try data.write(to: try directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = try? directory.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.zuno.decode(type, from: data)
    }

    func removeAll() {
        guard let url = try? directory else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Offline cache of issued tickets so a QR can be shown at the door without a connection.
actor TicketCache {
    private let store: SecureFileStore
    init(store: SecureFileStore = .standard) { self.store = store }

    private func name(for userID: UUID) -> String { "tickets-\(userID.uuidString.lowercased()).json" }

    func save(_ tickets: [Ticket], for userID: UUID) {
        try? store.write(tickets, to: name(for: userID))
    }

    func load(for userID: UUID) -> [Ticket] {
        store.read([Ticket].self, from: name(for: userID)) ?? []
    }

    func clear() { store.removeAll() }
}

enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case dark, light, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: String(localized: "Dark (recommended)")
        case .light: String(localized: "Light")
        case .system: String(localized: "Match system")
        }
    }
}

/// Non-sensitive preferences in UserDefaults. Nothing secret or identifying lives here.
@MainActor
@Observable
final class AppPreferences {
    private let defaults: UserDefaults

    var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarding) } }
    var appearance: AppearancePreference { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    var selectedCity: String { didSet { defaults.set(selectedCity, forKey: Keys.city) } }
    var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Keys.recents) } }
    var identityPromptDeferred: Bool { didSet { defaults.set(identityPromptDeferred, forKey: Keys.identityDeferred) } }
    var pushPromptShown: Bool { didSet { defaults.set(pushPromptShown, forKey: Keys.pushPrompt) } }

    private enum Keys {
        static let onboarding = "onboarding.completed"
        static let appearance = "appearance"
        static let city = "location.city"
        static let recents = "search.recents"
        static let identityDeferred = "identity.deferred"
        static let pushPrompt = "push.promptShown"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        appearance = AppearancePreference(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .dark
        selectedCity = defaults.string(forKey: Keys.city) ?? SriLankaLocations.defaultPlace.city
        recentSearches = defaults.stringArray(forKey: Keys.recents) ?? []
        identityPromptDeferred = defaults.bool(forKey: Keys.identityDeferred)
        pushPromptShown = defaults.bool(forKey: Keys.pushPrompt)
    }

    func addRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
    }

    /// Clears per-user conveniences on sign-out (keeps onboarding + appearance).
    func clearUserState() {
        recentSearches = []
        identityPromptDeferred = false
    }

    func resetAll() {
        for key in [Keys.onboarding, Keys.appearance, Keys.city, Keys.recents, Keys.identityDeferred, Keys.pushPrompt] {
            defaults.removeObject(forKey: key)
        }
        hasCompletedOnboarding = false
        appearance = .dark
        selectedCity = SriLankaLocations.defaultPlace.city
        recentSearches = []
        identityPromptDeferred = false
        pushPromptShown = false
    }
}

extension JSONEncoder {
    static var zuno: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var zuno: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = ServerDate.parse(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(raw)")
        }
        return decoder
    }
}

/// Parses PostgREST timestamps (with or without fractional seconds / offsets).
enum ServerDate {
    static func parse(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? Date(raw, strategy: fractional) { return date }
        // Postgres can emit "2026-10-12 18:30:00+05:30" or "2026-10-12T18:30:00.123456+00:00".
        var normalized = raw.replacingOccurrences(of: " ", with: "T")
        if let dot = normalized.firstIndex(of: "."), let zone = normalized[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let fraction = normalized[normalized.index(after: dot)..<zone].prefix(3)
            normalized = String(normalized[..<dot]) + "." + fraction + String(normalized[zone...])
        }
        if normalized.hasSuffix("+00") || normalized.range(of: #"[+-]\d{2}$"#, options: .regularExpression) != nil {
            normalized += ":00"
        }
        return (try? Date(normalized, strategy: fractional)) ?? (try? Date(normalized, strategy: .iso8601))
    }
}
