import Foundation

// Wire formats from docs/BACKEND_CONTRACT.md. Decoded with `JSONDecoder.zunoSnake`
// (snake_case → camelCase), then mapped into domain models.

extension JSONDecoder {
    static var zunoSnake: JSONDecoder {
        let decoder = JSONDecoder.zuno
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

enum StorageBucket {
    static let eventMedia = "event-media"
    static let avatars = "avatars"
}

struct CategoryRow: Decodable {
    let id: String
    let name: String
    let symbolName: String
    let sortOrder: Int

    var domain: EventCategory { EventCategory(id: id, name: name, symbolName: symbolName, sortOrder: sortOrder) }
}

struct EventCardRow: Decodable {
    let id: UUID
    let title: String
    let summary: String?
    let categoryId: String
    let categoryName: String?
    let organizerId: UUID
    let organizerName: String?
    let venueName: String?
    let city: String?
    let district: String?
    let latitude: Double?
    let longitude: Double?
    let university: String?
    let format: EventFormat
    let startsAt: Date
    let endsAt: Date
    let isFree: Bool
    let minPriceMinor: Int64?
    let currency: String?
    let capacity: Int
    let seatsRemaining: Int?
    let seatsTaken: Int?
    let coverPath: String?
    let coverAlt: String?
    let tags: [String]?
    let status: EventStatus

    var domain: EventSummary {
        let location: GeoPoint? = if let latitude, let longitude { GeoPoint(latitude: latitude, longitude: longitude) } else { nil }
        let currency = self.currency ?? "LKR"
        return EventSummary(
            id: id,
            title: title,
            summary: summary ?? "",
            categoryID: categoryId,
            categoryName: categoryName ?? categoryId.capitalized,
            organizerID: organizerId,
            organizerName: organizerName ?? "",
            venueName: venueName,
            city: city,
            district: district,
            location: location,
            university: university,
            format: format,
            startsAt: startsAt,
            endsAt: endsAt,
            isFree: isFree,
            minPrice: minPriceMinor.map { Money(minorUnits: $0, currency: currency) },
            capacity: capacity,
            seatsRemaining: seatsRemaining ?? max(capacity - (seatsTaken ?? 0), 0),
            cover: coverPath.map { .storage(bucket: StorageBucket.eventMedia, path: $0) },
            coverAlt: coverAlt,
            tags: tags ?? [],
            status: status
        )
    }
}

struct AgendaRow: Codable {
    let startsAt: Date
    let endsAt: Date
    let title: String
    let detail: String?

    var domain: AgendaItem { AgendaItem(startsAt: startsAt, endsAt: endsAt, title: title, detail: detail ?? "") }
}

struct SpeakerRow: Decodable {
    let name: String
    let role: String?
    let organization: String?
    var domain: Speaker { Speaker(name: name, role: role ?? "", organization: organization ?? "") }
}

struct EventDetailEnvelope: Decodable {
    struct DetailEvent: Decodable {
        let card: EventCardRow
        let description: String?
        let agenda: [AgendaRow]?
        let speakers: [SpeakerRow]?
        let refundPolicy: String?
        let registrationOpensAt: Date?
        let registrationClosesAt: Date?
        let onlineUrl: String?
        let addressLine: String?
        let organizerVerified: Bool?

        private enum CodingKeys: String, CodingKey {
            case description, agenda, speakers, refundPolicy, registrationOpensAt, registrationClosesAt, onlineUrl, addressLine, organizerVerified
        }

        init(from decoder: Decoder) throws {
            card = try EventCardRow(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            agenda = try c.decodeIfPresent([AgendaRow].self, forKey: .agenda)
            speakers = try c.decodeIfPresent([SpeakerRow].self, forKey: .speakers)
            refundPolicy = try c.decodeIfPresent(String.self, forKey: .refundPolicy)
            registrationOpensAt = try c.decodeIfPresent(Date.self, forKey: .registrationOpensAt)
            registrationClosesAt = try c.decodeIfPresent(Date.self, forKey: .registrationClosesAt)
            onlineUrl = try c.decodeIfPresent(String.self, forKey: .onlineUrl)
            addressLine = try c.decodeIfPresent(String.self, forKey: .addressLine)
            organizerVerified = try c.decodeIfPresent(Bool.self, forKey: .organizerVerified)
        }
    }

    struct TierRow: Decodable {
        let id: UUID
        let name: String
        let description: String?
        let priceMinor: Int64
        let currency: String?
        let quantity: Int
        let remaining: Int
        let maxPerOrder: Int?
        let salesStartAt: Date?
        let salesEndAt: Date?
        let onSale: Bool?

        var domain: TicketTier {
            TicketTier(id: id, name: name, description: description ?? "",
                       price: Money(minorUnits: priceMinor, currency: currency ?? "LKR"),
                       quantity: quantity, remaining: remaining, maxPerOrder: maxPerOrder ?? 10,
                       salesStartAt: salesStartAt, salesEndAt: salesEndAt, onSale: onSale ?? true)
        }
    }

    struct QuestionRow: Decodable {
        let id: UUID
        let prompt: String
        let kind: QuestionKind
        let options: [String]?
        let required: Bool?
        var domain: RegistrationQuestion {
            RegistrationQuestion(id: id, prompt: prompt, kind: kind, options: options ?? [], required: required ?? false)
        }
    }

    struct MediaRow: Decodable {
        let storagePath: String
        let kind: String?
        let altText: String?
    }

    struct ViewerRow: Decodable {
        let isSaved: Bool?
        let registrationStatus: RegistrationStatus?
        let registrationId: UUID?
        let isOrganizer: Bool?
    }

    let event: DetailEvent
    let tiers: [TierRow]?
    let questions: [QuestionRow]?
    let media: [MediaRow]?
    let viewer: ViewerRow?

    var domain: EventDetail {
        EventDetail(
            summary: event.card.domain,
            description: event.description ?? "",
            addressLine: event.addressLine,
            onlineURL: event.onlineUrl.flatMap(URL.init(string:)),
            agenda: (event.agenda ?? []).map(\.domain),
            speakers: (event.speakers ?? []).map(\.domain),
            refundPolicy: event.refundPolicy,
            registrationOpensAt: event.registrationOpensAt,
            registrationClosesAt: event.registrationClosesAt,
            organizerVerified: event.organizerVerified ?? false,
            tiers: (tiers ?? []).map(\.domain),
            questions: (questions ?? []).map(\.domain),
            gallery: (media ?? []).filter { $0.kind != "cover" }.map {
                EventMedia(image: .storage(bucket: StorageBucket.eventMedia, path: $0.storagePath), altText: $0.altText)
            },
            viewer: ViewerState(
                isSaved: viewer?.isSaved ?? false,
                registrationStatus: viewer?.registrationStatus,
                registrationID: viewer?.registrationId,
                isOrganizer: viewer?.isOrganizer ?? false
            )
        )
    }
}

struct QuoteRow: Decodable {
    let allowanceLimit: Int
    let allowanceUsed: Int
    let allowanceRemaining: Int
    let feeMinor: Int64
    let walletBalanceMinor: Int64
    let currency: String?
    let canRegister: Bool
    let reason: String?
    let seatsRemaining: Int?
    let month: String

    var domain: FreeRegistrationQuote {
        let currency = self.currency ?? "LKR"
        return FreeRegistrationQuote(
            allowanceLimit: allowanceLimit, allowanceUsed: allowanceUsed, allowanceRemaining: allowanceRemaining,
            fee: Money(minorUnits: feeMinor, currency: currency),
            walletBalance: Money(minorUnits: walletBalanceMinor, currency: currency),
            canRegister: canRegister,
            reason: reason.flatMap(RegistrationBlockReason.init(rawValue:)),
            seatsRemaining: seatsRemaining ?? 0,
            month: month
        )
    }
}

struct RegistrationResultRow: Decodable {
    let registrationId: UUID
    let reference: String
    let ticketId: UUID?
    let feeMinor: Int64
    let allowanceRemaining: Int
    let walletBalanceMinor: Int64
    let status: RegistrationStatus

    var domain: RegistrationConfirmation {
        RegistrationConfirmation(registrationID: registrationId, reference: reference, ticketID: ticketId,
                                 fee: .lkr(feeMinor), allowanceRemaining: allowanceRemaining,
                                 walletBalance: .lkr(walletBalanceMinor), status: status)
    }
}

struct TicketEventRow: Decodable {
    let id: UUID
    let title: String
    let startsAt: Date
    let endsAt: Date
    let venueName: String?
    let city: String?
    let coverPath: String?
    let coverAlt: String?
    let status: EventStatus
    let categoryId: String?

    var domain: TicketEventInfo {
        TicketEventInfo(id: id, title: title, startsAt: startsAt, endsAt: endsAt, venueName: venueName, city: city,
                        cover: coverPath.map { .storage(bucket: StorageBucket.eventMedia, path: $0) }, coverAlt: coverAlt,
                        status: status, categoryID: categoryId ?? "community")
    }
}

struct TicketRow: Decodable {
    let ticketId: UUID
    let code: String
    let qrPayload: String
    let status: TicketStatus
    let tierName: String?
    let attendeeName: String?
    let issuedAt: Date
    let checkedInAt: Date?
    let registrationReference: String?
    let orderId: UUID?
    let event: TicketEventRow

    var domain: Ticket {
        Ticket(id: ticketId, code: code, qrPayload: qrPayload, status: status,
               tierName: tierName ?? String(localized: "General admission"), attendeeName: attendeeName ?? "",
               issuedAt: issuedAt, checkedInAt: checkedInAt, registrationReference: registrationReference ?? "",
               orderID: orderId, event: event.domain)
    }
}

struct RegistrationHistoryRow: Decodable {
    let registrationId: UUID
    let status: RegistrationStatus
    let kind: RegistrationKind
    let feeMinor: Int64?
    let reference: String
    let createdAt: Date
    let event: TicketEventRow

    var domain: RegistrationRecord {
        RegistrationRecord(id: registrationId, event: event.domain, status: status, kind: kind,
                           fee: .lkr(feeMinor ?? 0), reference: reference, createdAt: createdAt)
    }
}

struct WalletSummaryRow: Decodable {
    let balanceMinor: Int64
    let currency: String?
    let allowanceLimit: Int
    let allowanceUsed: Int
    let allowanceRemaining: Int
    let extraFeeMinor: Int64
    let month: String
    let pendingTopupsMinor: Int64?

    var domain: WalletSummary {
        let currency = self.currency ?? "LKR"
        return WalletSummary(balance: Money(minorUnits: balanceMinor, currency: currency), allowanceLimit: allowanceLimit,
                             allowanceUsed: allowanceUsed, allowanceRemaining: allowanceRemaining,
                             extraFee: Money(minorUnits: extraFeeMinor, currency: currency), month: month,
                             pendingTopUps: Money(minorUnits: pendingTopupsMinor ?? 0, currency: currency))
    }
}

struct LedgerRow: Decodable {
    let id: UUID
    let entryType: WalletEntryType
    let amountMinor: Int64
    let balanceAfterMinor: Int64?
    let status: LedgerStatus
    let referenceType: String?
    let referenceId: UUID?
    let description: String?
    let createdAt: Date

    var domain: WalletTransaction {
        WalletTransaction(id: id, type: entryType, amount: .lkr(amountMinor), balanceAfter: balanceAfterMinor.map(Money.lkr),
                          status: status, description: description ?? entryType.title, referenceType: referenceType,
                          referenceID: referenceId, createdAt: createdAt)
    }
}

struct OrderRow: Decodable {
    let id: UUID
    let kind: OrderKind
    let status: OrderStatus
    let totalMinor: Int64
    let currency: String?
    let eventId: UUID?
    let paidAt: Date?
    let createdAt: Date

    var domain: OrderSnapshot {
        OrderSnapshot(id: id, kind: kind, status: status, total: Money(minorUnits: totalMinor, currency: currency ?? "LKR"),
                      eventID: eventId, paidAt: paidAt, createdAt: createdAt)
    }
}

struct CheckoutResponse: Decodable {
    struct Summary: Decodable {
        struct Line: Decodable {
            let label: String
            let quantity: Int
            let unitPriceMinor: Int64
            let amountMinor: Int64
        }
        let lines: [Line]
        let subtotalMinor: Int64
        let commissionMinor: Int64
        let totalMinor: Int64
        let currency: String?
    }

    struct Checkout: Decodable {
        let actionUrl: URL
        let method: String?
        let fields: [String: String]
    }

    let orderId: UUID
    let status: OrderStatus
    let expiresAt: Date
    let summary: Summary
    let checkout: Checkout

    var domain: CheckoutSession {
        let currency = summary.currency ?? "LKR"
        let money = { (minor: Int64) in Money(minorUnits: minor, currency: currency) }
        return CheckoutSession(
            orderID: orderId,
            expiresAt: expiresAt,
            summary: OrderSummary(
                lines: summary.lines.map { OrderLine(label: $0.label, quantity: $0.quantity, unitPrice: money($0.unitPriceMinor), amount: money($0.amountMinor)) },
                subtotal: money(summary.subtotalMinor),
                commission: money(summary.commissionMinor),
                total: money(summary.totalMinor)
            ),
            payment: .payHere(
                actionURL: checkout.actionUrl,
                fields: checkout.fields,
                returnURL: checkout.fields["return_url"] ?? "",
                cancelURL: checkout.fields["cancel_url"] ?? ""
            )
        )
    }
}

struct ProfileRow: Codable {
    let id: UUID
    let displayName: String?
    let avatarPath: String?
    let city: String?
    let district: String?
    let preferredCategories: [String]?
    let language: String?
    let accessibilityNeeds: [String]?
    let phone: String?
    let identityStatus: String?
    let onboardingCompletedAt: Date?

    var domain: UserProfile {
        UserProfile(
            id: id,
            displayName: displayName ?? "",
            avatarPath: avatarPath,
            city: city,
            district: district,
            preferredCategories: preferredCategories ?? [],
            language: AppLanguage(rawValue: language ?? "en") ?? .en,
            accessibilityNeeds: (accessibilityNeeds ?? []).compactMap(AccessibilityNeed.init(rawValue:)),
            phone: phone,
            identityStatus: IdentityStatus(rawValue: identityStatus ?? "none") ?? .none,
            onboardingCompletedAt: onboardingCompletedAt
        )
    }
}

struct NotificationDTO: Decodable {
    let id: UUID
    let kind: NotificationKind
    let title: String
    let body: String
    let eventId: UUID?
    let readAt: Date?
    let createdAt: Date

    var domain: AppNotification {
        AppNotification(id: id, kind: kind, title: title, body: body, eventID: eventId, readAt: readAt, createdAt: createdAt)
    }
}

struct OrganizerProfileRow: Decodable {
    let id: UUID
    let name: String
    let slug: String
    let bio: String?
    let logoPath: String?
    let contactEmail: String?
    let verificationStatus: OrganizerVerification

    var domain: OrganizerProfile {
        OrganizerProfile(id: id, name: name, slug: slug, bio: bio ?? "", logoPath: logoPath, contactEmail: contactEmail ?? "",
                         verification: verificationStatus)
    }
}

struct DashboardRow: Decodable {
    struct EventRow: Decodable {
        let card: EventCardRow
        let registrations: Int
        let checkedIn: Int

        private enum CodingKeys: String, CodingKey { case registrations, checkedIn }
        init(from decoder: Decoder) throws {
            card = try EventCardRow(from: decoder)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            registrations = try c.decodeIfPresent(Int.self, forKey: .registrations) ?? 0
            checkedIn = try c.decodeIfPresent(Int.self, forKey: .checkedIn) ?? 0
        }
    }
    struct Totals: Decodable {
        let grossMinor: Int64
        let commissionMinor: Int64
        let netMinor: Int64
    }
    let organizer: OrganizerProfileRow
    let events: [EventRow]
    let totals: Totals

    var domain: OrganizerDashboard {
        OrganizerDashboard(
            organizer: organizer.domain,
            events: events.map { OrganizerEventRow(event: $0.card.domain, registrations: $0.registrations, checkedIn: $0.checkedIn) },
            totals: SalesTotals(gross: .lkr(totals.grossMinor), commission: .lkr(totals.commissionMinor), net: .lkr(totals.netMinor))
        )
    }
}

struct EventStatsRow: Decodable {
    struct TierRow: Decodable {
        let tierId: UUID
        let name: String
        let sold: Int
        let quantity: Int
        let grossMinor: Int64
    }
    let capacity: Int
    let registrations: Int
    let waitlisted: Int
    let checkedIn: Int
    let ticketsSold: Int
    let grossMinor: Int64
    let commissionMinor: Int64
    let netMinor: Int64
    let byTier: [TierRow]?

    var domain: OrganizerEventStats {
        OrganizerEventStats(capacity: capacity, registrations: registrations, waitlisted: waitlisted, checkedIn: checkedIn,
                            ticketsSold: ticketsSold, gross: .lkr(grossMinor), commission: .lkr(commissionMinor), net: .lkr(netMinor),
                            byTier: (byTier ?? []).map { TierSales(tierID: $0.tierId, name: $0.name, sold: $0.sold, quantity: $0.quantity, gross: .lkr($0.grossMinor)) })
    }
}

struct AttendeeRowDTO: Decodable {
    let ticketId: UUID
    let attendeeName: String?
    let tierName: String?
    let status: TicketStatus
    let checkedInAt: Date?
    let registrationReference: String?

    var domain: AttendeeRow {
        AttendeeRow(ticketID: ticketId, attendeeName: attendeeName ?? "", tierName: tierName ?? "", status: status,
                    checkedInAt: checkedInAt, registrationReference: registrationReference ?? "")
    }
}

struct SettlementRowDTO: Decodable {
    let eventId: UUID
    let title: String
    let grossMinor: Int64
    let commissionMinor: Int64
    let netMinor: Int64
    let payoutStatus: PayoutStatus?

    var domain: SettlementRow {
        SettlementRow(eventID: eventId, title: title, gross: .lkr(grossMinor), commission: .lkr(commissionMinor),
                      net: .lkr(netMinor), payoutStatus: payoutStatus ?? .unsettled)
    }
}

struct CheckInRow: Decodable {
    let result: CheckInResult
    let attendeeName: String?
    let tierName: String?
    let checkedInAt: Date?

    var domain: CheckInOutcome { CheckInOutcome(result: result, attendeeName: attendeeName, tierName: tierName, checkedInAt: checkedInAt) }
}

struct AIDraftResponse: Decodable {
    struct QuestionRow: Decodable {
        let prompt: String
        let kind: QuestionKind
        let options: [String]?
        let required: Bool?
    }
    let draftId: UUID
    let kind: AIDraftKind
    let agenda: [AgendaRow]?
    let questions: [QuestionRow]?

    var domain: AIDraftResult {
        AIDraftResult(draftID: draftId, kind: kind, agenda: (agenda ?? []).map(\.domain),
                      questions: (questions ?? []).map { QuestionDraft(prompt: $0.prompt, kind: $0.kind, options: $0.options ?? [], required: $0.required ?? false) })
    }
}

struct VenueRow: Decodable {
    let id: UUID
    let name: String
    let addressLine: String?
    let city: String?
    let district: String?
    let latitude: Double?
    let longitude: Double?

    var domain: Venue {
        Venue(id: id, name: name, addressLine: addressLine ?? "", city: city ?? "", district: district ?? "",
              location: latitude.flatMap { lat in longitude.map { GeoPoint(latitude: lat, longitude: $0) } })
    }
}

struct EventDraftRow: Decodable {
    let id: UUID
    let organizerId: UUID
    let categoryId: String
    let venueId: UUID?
    let title: String
    let summary: String?
    let description: String?
    let format: EventFormat
    let startsAt: Date
    let endsAt: Date
    let capacity: Int
    let isFree: Bool
    let university: String?
    let tags: [String]?
    let coverPath: String?
    let coverAlt: String?
    let agenda: [AgendaRow]?
    let speakers: [SpeakerRow]?
    let refundPolicy: String?
    let registrationClosesAt: Date?
    let onlineUrl: String?
    let status: EventStatus
    let creationFeePaidAt: Date?
}
