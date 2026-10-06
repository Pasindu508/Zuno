import Foundation

enum AppLanguage: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case en, si, ta
    var id: String { rawValue }

    /// Shown in each language's own script.
    var nativeName: String {
        switch self {
        case .en: "English"
        case .si: "සිංහල"
        case .ta: "தமிழ்"
        }
    }

    var locale: Locale {
        switch self {
        case .en: Locale(identifier: "en_LK")
        case .si: Locale(identifier: "si_LK")
        case .ta: Locale(identifier: "ta_LK")
        }
    }
}

enum AccessibilityNeed: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case wheelchairAccess = "wheelchair_access"
    case signLanguage = "sign_language"
    case quietSpace = "quiet_space"
    case largePrint = "large_print"
    case assistedEntry = "assisted_entry"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wheelchairAccess: String(localized: "Step-free / wheelchair access")
        case .signLanguage: String(localized: "Sign language interpretation")
        case .quietSpace: String(localized: "Quiet space")
        case .largePrint: String(localized: "Large-print materials")
        case .assistedEntry: String(localized: "Assisted entry")
        }
    }

    var symbolName: String {
        switch self {
        case .wheelchairAccess: "figure.roll"
        case .signLanguage: "hand.wave"
        case .quietSpace: "ear"
        case .largePrint: "textformat.size"
        case .assistedEntry: "person.2"
        }
    }
}

enum IdentityStatus: String, Codable, Sendable, Hashable {
    case none
    case verifiedUnique = "verified_unique"
    case duplicate
}

struct UserProfile: Identifiable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var avatarPath: String?
    var city: String?
    var district: String?
    var preferredCategories: [String]
    var language: AppLanguage
    var accessibilityNeeds: [AccessibilityNeed]
    var phone: String?
    var identityStatus: IdentityStatus
    var onboardingCompletedAt: Date?

    /// Profile setup (name, place, preferences) has been completed.
    var isComplete: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty && city != nil && onboardingCompletedAt != nil
    }

    var hasIdentitySetup: Bool { identityStatus == .verifiedUnique }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

struct ProfileDraft: Hashable, Sendable {
    var displayName: String = ""
    var avatarPath: String?
    var city: String = "Colombo"
    var district: String = "Colombo"
    var preferredCategories: Set<String> = []
    var language: AppLanguage = .en
    var accessibilityNeeds: Set<AccessibilityNeed> = []
    var phone: String = ""

    init() {}

    init(profile: UserProfile) {
        displayName = profile.displayName
        avatarPath = profile.avatarPath
        city = profile.city ?? "Colombo"
        district = profile.district ?? "Colombo"
        preferredCategories = Set(profile.preferredCategories)
        language = profile.language
        accessibilityNeeds = Set(profile.accessibilityNeeds)
        phone = profile.phone ?? ""
    }

    var isValid: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (2...60).contains(name.count) && !city.isEmpty
    }
}

enum IdentityCheckResult: String, Sendable, Hashable, Codable {
    case verifiedUnique = "verified_unique"
    case duplicate
}

/// Sri Lankan NIC handling on the device: format checks and whitespace normalisation for
/// transmission only. The device never hashes, stores or logs the number; the protected
/// Edge Function canonicalises and HMACs it server-side.
enum NICInput {
    enum Format: Equatable { case old, new }

    /// Uppercases and removes spaces and dashes.
    static func normalizeForTransmission(_ raw: String) -> String {
        raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    static func format(of raw: String) -> Format? {
        let value = normalizeForTransmission(raw)
        if value.count == 12, value.allSatisfy(\.isASCIIDigit) { return .new }
        if value.count == 10, value.prefix(9).allSatisfy(\.isASCIIDigit), let last = value.last, last == "V" || last == "X" {
            return .old
        }
        return nil
    }

    static func isPlausible(_ raw: String) -> Bool { format(of: raw) != nil }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
