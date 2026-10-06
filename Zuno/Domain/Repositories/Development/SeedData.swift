#if DEBUG
import Foundation

/// Decodes `supabase/seed/zuno_seed.json` — the same file `supabase/seed.sql` is generated
/// from — so the development backend and the database seed never drift apart.
struct SeedDocument: Decodable {
    struct Organizer: Decodable {
        let id: UUID
        let ownerId: UUID
        let name: String
        let slug: String
        let bio: String
        let contactEmail: String
        let verificationStatus: OrganizerVerification
    }

    struct VenueSeed: Decodable {
        let id: UUID
        let organizerId: UUID
        let name: String
        let addressLine: String
        let city: String
        let district: String
        let latitude: Double
        let longitude: Double
    }

    struct AgendaSeed: Decodable {
        let offsetHours: Double
        let durationHours: Double
        let title: String
        let detail: String
    }

    struct QuestionSeed: Decodable {
        let prompt: String
        let kind: QuestionKind
        let options: [String]
        let required: Bool
    }

    struct TierSeed: Decodable {
        let id: UUID
        let name: String
        let description: String
        let priceMinor: Int64
        let quantity: Int
        let sold: Int
        let maxPerOrder: Int
    }

    struct EventSeed: Decodable {
        let id: UUID
        let slug: String
        let organizerId: UUID
        let categoryId: String
        let venueId: UUID?
        let title: String
        let summary: String
        let description: String
        let format: EventFormat
        let startOffsetDays: Int
        let startTime: String
        let durationHours: Double
        let capacity: Int
        let seatsTaken: Int
        let isFree: Bool
        let university: String?
        let tags: [String]
        let coverAlt: String
        let refundPolicy: String
        let agenda: [AgendaSeed]
        let speakers: [SpeakerSeed]
        let questions: [QuestionSeed]
        let tiers: [TierSeed]
    }

    struct SpeakerSeed: Decodable {
        let name: String
        let role: String
        let organization: String
    }

    struct DevelopmentUser: Decodable {
        let id: UUID
        let email: String
        let displayName: String
        let city: String
        let district: String
        let preferredCategories: [String]
        let walletBalanceMinor: Int64
        let allowanceUsedThisMonth: Int
        let registeredEventSlugs: [String]
        let paidTicketEventSlugs: [String]
        let savedEventSlugs: [String]
    }

    let categories: [CategoryRow]
    let organizers: [Organizer]
    let venues: [VenueSeed]
    let events: [EventSeed]
    let developmentUser: DevelopmentUser

    static func load(bundle: Bundle = .main) throws -> SeedDocument {
        guard let url = bundle.url(forResource: "zuno_seed", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder.zunoSnake.decode(SeedDocument.self, from: Data(contentsOf: url))
    }

    /// Start date for a seed event: `start_offset_days` after today (Colombo) at `start_time`.
    static func startDate(offsetDays: Int, time: String, now: Date) -> Date {
        let calendar = Calendar.colombo
        let parts = time.split(separator: ":").compactMap { Int($0) }
        let day = calendar.date(byAdding: .day, value: offsetDays, to: calendar.startOfDay(for: now))!
        return calendar.date(bySettingHour: parts.first ?? 9, minute: parts.count > 1 ? parts[1] : 0, second: 0, of: day)!
    }
}
#endif
