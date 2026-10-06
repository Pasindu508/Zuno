import Foundation
import Supabase

/// Shared helpers for live repositories.
struct SupabaseGateway: Sendable {
    let client: SupabaseClient

    func currentUserID() async throws -> UUID {
        guard let user = client.auth.currentUser else { throw ZunoError.notAuthenticated }
        return user.id
    }

    func rpc<T: Decodable>(_ name: String, _ params: some Encodable & Sendable, as type: T.Type) async throws -> T {
        do {
            let response = try await client.rpc(name, params: params).execute()
            return try JSONDecoder.zunoSnake.decode(T.self, from: response.data)
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func rpc(_ name: String, _ params: some Encodable & Sendable) async throws {
        do {
            _ = try await client.rpc(name, params: params).execute()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ request: () async throws -> PostgrestResponse<Void>) async throws -> T {
        do {
            return try JSONDecoder.zunoSnake.decode(T.self, from: try await request().data)
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func invoke<T: Decodable>(_ function: String, body: some Encodable & Sendable, as type: T.Type) async throws -> T {
        do {
            return try await client.functions.invoke(function, options: FunctionInvokeOptions(body: body), decoder: JSONDecoder.zunoSnake)
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }
}

private struct EventIDParam: Encodable, Sendable { let p_event_id: UUID }
private struct NoParams: Encodable, Sendable {}

// MARK: - Events

struct SupabaseEventRepository: EventRepository {
    let gateway: SupabaseGateway

    func categories() async throws -> [EventCategory] {
        try await gateway.decode([CategoryRow].self) {
            try await gateway.client.from("categories").select().order("sort_order").execute()
        }.map(\.domain)
    }

    func searchEvents(query: String?, filters: EventFilters, limit: Int) async throws -> [EventSummary] {
        struct Params: Encodable, Sendable {
            let p_query: String?
            let p_filters: [String: AnyJSON]
            let p_limit: Int
            let p_offset: Int
        }
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = Params(p_query: trimmed?.isEmpty == false ? trimmed : nil,
                            p_filters: filters.serverPayload(now: .now), p_limit: limit, p_offset: 0)
        return try await gateway.rpc("search_events", params, as: [EventCardRow].self).map(\.domain)
    }

    func eventDetail(id: UUID) async throws -> EventDetail {
        try await gateway.rpc("get_event_detail", EventIDParam(p_event_id: id), as: EventDetailEnvelope.self).domain
    }

    func savedEventIDs() async throws -> Set<UUID> {
        struct Row: Decodable { let eventId: UUID }
        guard gateway.client.auth.currentUser != nil else { return [] }
        let rows = try await gateway.decode([Row].self) {
            try await gateway.client.from("saved_events").select("event_id").execute()
        }
        return Set(rows.map(\.eventId))
    }

    func setSaved(_ saved: Bool, eventID: UUID) async throws {
        let userID = try await gateway.currentUserID()
        do {
            if saved {
                struct Insert: Encodable { let user_id: UUID; let event_id: UUID }
                try await gateway.client.from("saved_events")
                    .upsert(Insert(user_id: userID, event_id: eventID), onConflict: "user_id,event_id", ignoreDuplicates: true)
                    .execute()
            } else {
                try await gateway.client.from("saved_events").delete()
                    .eq("user_id", value: userID).eq("event_id", value: eventID).execute()
            }
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func savedEvents() async throws -> [EventSummary] {
        let ids = try await savedEventIDs()
        guard !ids.isEmpty else { return [] }
        return try await gateway.decode([EventCardRow].self) {
            try await gateway.client.from("event_cards").select().in("id", values: ids.map(\.uuidString)).order("starts_at").execute()
        }.map(\.domain)
    }

    func followedOrganizerIDs() async throws -> Set<UUID> {
        struct Row: Decodable { let organizerId: UUID }
        guard gateway.client.auth.currentUser != nil else { return [] }
        let rows = try await gateway.decode([Row].self) {
            try await gateway.client.from("saved_organizers").select("organizer_id").execute()
        }
        return Set(rows.map(\.organizerId))
    }

    func setFollowing(_ following: Bool, organizerID: UUID) async throws {
        let userID = try await gateway.currentUserID()
        do {
            if following {
                struct Insert: Encodable { let user_id: UUID; let organizer_id: UUID }
                try await gateway.client.from("saved_organizers")
                    .upsert(Insert(user_id: userID, organizer_id: organizerID), onConflict: "user_id,organizer_id", ignoreDuplicates: true)
                    .execute()
            } else {
                try await gateway.client.from("saved_organizers").delete()
                    .eq("user_id", value: userID).eq("organizer_id", value: organizerID).execute()
            }
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }
}

extension EventFilters {
    /// `p_filters` for `search_events` (contract §3).
    func serverPayload(now: Date) -> [String: AnyJSON] {
        var payload: [String: AnyJSON] = [:]
        let iso = Date.ISO8601FormatStyle()
        if let interval = dateRange.interval(now: now) {
            payload["date_from"] = .string(interval.start.formatted(iso))
            payload["date_to"] = .string(interval.end.formatted(iso))
        }
        if !cities.isEmpty { payload["cities"] = .array(cities.sorted().map(AnyJSON.string)) }
        if let origin, let radiusKm {
            payload["near_lat"] = .double(origin.latitude)
            payload["near_lng"] = .double(origin.longitude)
            payload["radius_km"] = .double(radiusKm)
        }
        if price != .any { payload["price"] = .string(price.rawValue) }
        if format != .any { payload["format"] = .string(format.rawValue) }
        if availableOnly { payload["available_only"] = .bool(true) }
        if !organizerIDs.isEmpty { payload["organizer_ids"] = .array(organizerIDs.map { .string($0.uuidString) }) }
        if !categoryIDs.isEmpty { payload["category_ids"] = .array(categoryIDs.sorted().map(AnyJSON.string)) }
        if let university { payload["university"] = .string(university) }
        return payload
    }
}

// MARK: - Registration

struct SupabaseRegistrationRepository: RegistrationRepository {
    let gateway: SupabaseGateway

    func quoteFreeRegistration(eventID: UUID) async throws -> FreeRegistrationQuote {
        try await gateway.rpc("quote_free_registration", EventIDParam(p_event_id: eventID), as: QuoteRow.self).domain
    }

    func registerFree(eventID: UUID, answers: [RegistrationAnswer], expectedFee: Money, idempotencyKey: String) async throws -> RegistrationConfirmation {
        struct Params: Encodable, Sendable {
            let p_event_id: UUID
            let p_answers: [RegistrationAnswer]
            let p_expected_fee_minor: Int64
            let p_idempotency_key: String
        }
        return try await gateway.rpc(
            "register_for_free_event",
            Params(p_event_id: eventID, p_answers: answers, p_expected_fee_minor: expectedFee.minorUnits, p_idempotency_key: idempotencyKey),
            as: RegistrationResultRow.self
        ).domain
    }

    func joinWaitlist(eventID: UUID) async throws -> WaitlistConfirmation {
        struct Row: Decodable { let registrationId: UUID; let position: Int? }
        let row = try await gateway.rpc("join_waitlist", EventIDParam(p_event_id: eventID), as: Row.self)
        return WaitlistConfirmation(registrationID: row.registrationId, position: row.position ?? 0)
    }

    func cancelRegistration(id: UUID) async throws {
        struct Params: Encodable, Sendable { let p_registration_id: UUID }
        try await gateway.rpc("cancel_registration", Params(p_registration_id: id))
    }

    func registrations() async throws -> [RegistrationRecord] {
        try await gateway.rpc("my_registrations", NoParams(), as: [RegistrationHistoryRow].self).map(\.domain)
    }
}

// MARK: - Checkout

struct SupabaseCheckoutRepository: CheckoutRepository {
    let gateway: SupabaseGateway

    func createCheckout(_ request: CheckoutRequest) async throws -> CheckoutSession {
        struct Body: Encodable, Sendable {
            let kind: String
            let event_id: UUID?
            let items: [CheckoutItem]?
            let answers: [RegistrationAnswer]?
            let amount_minor: Int64?
            let phone: String
            let idempotency_key: String
        }
        let body: Body = switch request.purpose {
        case .tickets(let eventID, let items, let answers):
            Body(kind: "ticket", event_id: eventID, items: items, answers: answers, amount_minor: nil, phone: request.phone, idempotency_key: request.idempotencyKey)
        case .walletTopUp(let amount):
            Body(kind: "wallet_topup", event_id: nil, items: nil, answers: nil, amount_minor: amount.minorUnits, phone: request.phone, idempotency_key: request.idempotencyKey)
        case .eventCreationFee(let eventID):
            Body(kind: "event_creation_fee", event_id: eventID, items: nil, answers: nil, amount_minor: nil, phone: request.phone, idempotency_key: request.idempotencyKey)
        }
        return try await gateway.invoke("payhere-checkout", body: body, as: CheckoutResponse.self).domain
    }

    func order(id: UUID) async throws -> OrderSnapshot {
        try await gateway.decode(OrderRow.self) {
            try await gateway.client.from("orders").select("id,kind,status,total_minor,currency,event_id,paid_at,created_at")
                .eq("id", value: id).single().execute()
        }.domain
    }

    #if DEBUG
    func simulateGatewayNotification(orderID: UUID, statusCode: Int) async throws {
        // Live builds never simulate payments; only PayHere's signed notification counts.
        throw ZunoError.server(code: "not_supported", message: nil)
    }
    #endif
}

// MARK: - Wallet & tickets

struct SupabaseWalletRepository: WalletRepository {
    let gateway: SupabaseGateway

    func summary() async throws -> WalletSummary {
        try await gateway.rpc("wallet_summary", NoParams(), as: WalletSummaryRow.self).domain
    }

    func transactions() async throws -> [WalletTransaction] {
        try await gateway.decode([LedgerRow].self) {
            try await gateway.client.from("wallet_ledger")
                .select("id,entry_type,amount_minor,balance_after_minor,status,reference_type,reference_id,description,created_at")
                .order("created_at", ascending: false).limit(200).execute()
        }.map(\.domain)
    }
}

struct SupabaseTicketRepository: TicketRepository {
    let gateway: SupabaseGateway
    func tickets() async throws -> [Ticket] {
        try await gateway.rpc("my_tickets", NoParams(), as: [TicketRow].self).map(\.domain)
    }
}

// MARK: - Profile & identity

struct SupabaseProfileRepository: ProfileRepository {
    let gateway: SupabaseGateway

    func currentProfile() async throws -> UserProfile? {
        let userID = try await gateway.currentUserID()
        let rows = try await gateway.decode([ProfileRow].self) {
            try await gateway.client.from("profiles").select().eq("id", value: userID).limit(1).execute()
        }
        return rows.first?.domain
    }

    func saveProfile(_ draft: ProfileDraft, markOnboardingComplete: Bool) async throws -> UserProfile {
        let userID = try await gateway.currentUserID()
        struct Upsert: Encodable, Sendable {
            let id: UUID
            let display_name: String
            let avatar_path: String?
            let city: String
            let district: String
            let preferred_categories: [String]
            let language: String
            let accessibility_needs: [String]
            let phone: String?
            let onboarding_completed_at: Date?
        }
        /// Same columns without `id` (not updatable by clients).
        struct ProfileUpdate: Encodable, Sendable {
            let display_name: String
            let avatar_path: String?
            let city: String
            let district: String
            let preferred_categories: [String]
            let language: String
            let accessibility_needs: [String]
            let phone: String?
            let onboarding_completed_at: Date?
            init(_ upsert: Upsert) {
                display_name = upsert.display_name
                avatar_path = upsert.avatar_path
                city = upsert.city
                district = upsert.district
                preferred_categories = upsert.preferred_categories
                language = upsert.language
                accessibility_needs = upsert.accessibility_needs
                phone = upsert.phone
                onboarding_completed_at = upsert.onboarding_completed_at
            }
        }
        let payload = Upsert(
            id: userID,
            display_name: draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            avatar_path: draft.avatarPath,
            city: draft.city,
            district: draft.district,
            preferred_categories: draft.preferredCategories.sorted(),
            language: draft.language.rawValue,
            accessibility_needs: draft.accessibilityNeeds.map(\.rawValue).sorted(),
            phone: SriLankaLocations.normalizedMobile(draft.phone),
            onboarding_completed_at: markOnboardingComplete ? .now : nil
        )
        // The sign-up trigger creates the row, so update first; insert only if it is missing.
        // (An upsert would also try to UPDATE `id`, which clients may not change.)
        let updated = try await gateway.decode([ProfileRow].self) {
            try await gateway.client.from("profiles").update(ProfileUpdate(payload)).eq("id", value: userID).select().execute()
        }
        if let row = updated.first { return row.domain }
        let inserted = try await gateway.decode([ProfileRow].self) {
            try await gateway.client.from("profiles").insert(payload).select().execute()
        }
        guard let row = inserted.first else { throw ZunoError.notFound }
        return row.domain
    }

    func uploadAvatar(_ jpegData: Data) async throws -> String {
        let userID = try await gateway.currentUserID()
        let path = "\(userID.uuidString.lowercased())/avatar-\(Int(Date.now.timeIntervalSince1970)).jpg"
        do {
            try await gateway.client.storage.from(StorageBucket.avatars)
                .upload(path, data: jpegData, options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true))
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
        return path
    }

    /// The NIC goes only to the protected function over TLS; it is never stored on device.
    func submitNationalIdentifier(_ value: String) async throws -> IdentityCheckResult {
        struct Body: Encodable, Sendable { let nic: String }
        struct Response: Decodable { let status: IdentityCheckResult }
        return try await gateway.invoke("nic-digest", body: Body(nic: NICInput.normalizeForTransmission(value)), as: Response.self).status
    }
}

// MARK: - Notifications

struct SupabaseNotificationRepository: NotificationRepository {
    let gateway: SupabaseGateway

    func notifications() async throws -> [AppNotification] {
        try await gateway.decode([NotificationDTO].self) {
            try await gateway.client.from("notifications").select("id,kind,title,body,event_id,read_at,created_at")
                .order("created_at", ascending: false).limit(100).execute()
        }.map(\.domain)
    }

    func markRead(ids: [UUID]) async throws {
        struct Params: Encodable, Sendable { let p_ids: [UUID] }
        guard !ids.isEmpty else { return }
        try await gateway.rpc("mark_notifications_read", Params(p_ids: ids))
    }

    func markAllRead() async throws {
        try await gateway.rpc("mark_all_notifications_read", NoParams())
    }

    func preferences() async throws -> NotificationPreferences {
        let rows: [NotificationPreferences] = try await {
            do {
                let response = try await gateway.client.from("notification_preferences")
                    .select("event_reminders,payment_updates,event_changes,waitlist_updates,organizer_news,push_enabled")
                    .limit(1).execute()
                return try JSONDecoder.zuno.decode([NotificationPreferences].self, from: response.data)
            } catch {
                throw SupabaseErrorMapper.map(error)
            }
        }()
        return rows.first ?? NotificationPreferences()
    }

    func updatePreferences(_ preferences: NotificationPreferences) async throws {
        let userID = try await gateway.currentUserID()
        do {
            try await gateway.client.from("notification_preferences").update(preferences).eq("user_id", value: userID).execute()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func registerPushToken(_ token: String, environment: String) async throws {
        let userID = try await gateway.currentUserID()
        struct Upsert: Encodable, Sendable { let user_id: UUID; let apns_token: String; let environment: String }
        do {
            // Insert-or-ignore: clients may insert their own token but not update rows.
            try await gateway.client.from("push_devices")
                .upsert(Upsert(user_id: userID, apns_token: token, environment: environment == "production" ? "production" : "sandbox"),
                        onConflict: "apns_token", ignoreDuplicates: true)
                .execute()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }

    func changes() async -> AsyncStream<Void> {
        let client = gateway.client
        guard let userID = client.auth.currentUser?.id else { return AsyncStream { $0.finish() } }
        let channel = client.channel("notifications-\(userID.uuidString.lowercased())")
        let stream = channel.postgresChange(AnyAction.self, schema: "public", table: "notifications",
                                            filter: .eq("user_id", value: userID.uuidString.lowercased()))
        return AsyncStream { continuation in
            let task = Task {
                do { try await channel.subscribeWithError() } catch { continuation.finish(); return }
                for await _ in stream { continuation.yield(()) }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await client.removeChannel(channel) }
            }
        }
    }
}

// MARK: - Organizer

struct SupabaseOrganizerRepository: OrganizerRepository {
    let gateway: SupabaseGateway
    let aiFunctionName: String

    func dashboard() async throws -> OrganizerDashboard? {
        let userID = try await gateway.currentUserID()
        let owned = try await gateway.decode([OrganizerProfileRow].self) {
            try await gateway.client.from("organizer_profiles")
                .select("id,name,slug,bio,logo_path,contact_email,verification_status").eq("owner_id", value: userID).limit(1).execute()
        }
        guard !owned.isEmpty else { return nil }
        return try await gateway.rpc("organizer_dashboard", NoParams(), as: DashboardRow.self).domain
    }

    func createOrganizerProfile(_ draft: OrganizerProfileDraft) async throws -> OrganizerProfile {
        let userID = try await gateway.currentUserID()
        struct Insert: Encodable, Sendable { let owner_id: UUID; let name: String; let slug: String; let bio: String; let contact_email: String }
        let rows = try await gateway.decode([OrganizerProfileRow].self) {
            try await gateway.client.from("organizer_profiles")
                .insert(Insert(owner_id: userID, name: draft.name, slug: draft.slug, bio: draft.bio, contact_email: draft.contactEmail))
                .select("id,name,slug,bio,logo_path,contact_email,verification_status").execute()
        }
        guard let row = rows.first else { throw ZunoError.notFound }
        return row.domain
    }

    func venues() async throws -> [Venue] {
        try await gateway.decode([VenueRow].self) {
            try await gateway.client.from("venues").select("id,name,address_line,city,district,latitude,longitude").order("name").execute()
        }.map(\.domain)
    }

    func createVenue(name: String, addressLine: String, city: String) async throws -> Venue {
        guard let organizer = try await dashboard()?.organizer else { throw ZunoError.notAuthenticated }
        let place = SriLankaLocations.place(named: city)
        struct Insert: Encodable, Sendable {
            let organizer_id: UUID; let name: String; let address_line: String; let city: String; let district: String
            let latitude: Double?; let longitude: Double?
        }
        let rows = try await gateway.decode([VenueRow].self) {
            try await gateway.client.from("venues").insert(Insert(
                organizer_id: organizer.id, name: name, address_line: addressLine, city: city, district: place?.district ?? city,
                latitude: place?.location.latitude, longitude: place?.location.longitude
            )).select("id,name,address_line,city,district,latitude,longitude").execute()
        }
        guard let row = rows.first else { throw ZunoError.notFound }
        return row.domain
    }

    func saveEventDraft(_ draft: EventDraft) async throws -> EventDraft {
        struct EventUpsert: Encodable, Sendable {
            let id: UUID; let organizer_id: UUID; let category_id: String; let venue_id: UUID?
            let title: String; let summary: String; let description: String; let format: String
            let starts_at: Date; let ends_at: Date; let capacity: Int; let is_free: Bool; let university: String?
            let tags: [String]; let cover_path: String?; let cover_alt: String; let agenda: [AgendaRow]; let speakers: [[String: String]]
            let refund_policy: String; let registration_closes_at: Date?; let online_url: String?
        }
        struct TierUpsert: Encodable, Sendable {
            let id: UUID; let event_id: UUID; let name: String; let description: String; let price_minor: Int64
            let currency: String; let quantity: Int; let max_per_order: Int; let sales_start_at: Date?; let sales_end_at: Date?; let sort_order: Int
        }
        struct QuestionUpsert: Encodable, Sendable {
            let id: UUID; let event_id: UUID; let prompt: String; let kind: String; let options: [String]; let required: Bool; let sort_order: Int
        }
        let event = EventUpsert(
            id: draft.id, organizer_id: draft.organizerID, category_id: draft.categoryID, venue_id: draft.format == .online ? nil : draft.venueID,
            title: draft.title, summary: draft.summary, description: draft.description, format: draft.format.rawValue,
            starts_at: draft.startsAt, ends_at: draft.endsAt, capacity: draft.capacity, is_free: draft.isFree,
            university: draft.university.isEmpty ? nil : draft.university, tags: draft.tags, cover_path: draft.coverPath,
            cover_alt: draft.coverAlt, agenda: draft.agenda.map { AgendaRow(startsAt: $0.startsAt, endsAt: $0.endsAt, title: $0.title, detail: $0.detail) },
            speakers: draft.speakers.map { ["name": $0.name, "role": $0.role, "organization": $0.organization] },
            refund_policy: draft.refundPolicy, registration_closes_at: draft.registrationClosesAt,
            online_url: draft.format == .physical ? nil : draft.onlineURL
        )
        struct EventUpdate: Encodable, Sendable {
            let category_id: String; let venue_id: UUID?; let title: String; let summary: String; let description: String
            let format: String; let starts_at: Date; let ends_at: Date; let capacity: Int; let is_free: Bool; let university: String?
            let tags: [String]; let cover_path: String?; let cover_alt: String; let agenda: [AgendaRow]; let speakers: [[String: String]]
            let refund_policy: String; let registration_closes_at: Date?; let online_url: String?
            init(_ e: EventUpsert) {
                category_id = e.category_id; venue_id = e.venue_id; title = e.title; summary = e.summary; description = e.description
                format = e.format; starts_at = e.starts_at; ends_at = e.ends_at; capacity = e.capacity; is_free = e.is_free
                university = e.university; tags = e.tags; cover_path = e.cover_path; cover_alt = e.cover_alt; agenda = e.agenda
                speakers = e.speakers; refund_policy = e.refund_policy; registration_closes_at = e.registration_closes_at; online_url = e.online_url
            }
        }
        struct IDRow: Decodable { let id: UUID }
        do {
            // Update the existing draft (id and organizer are immutable); insert if it's new.
            let updated = try await gateway.decode([IDRow].self) {
                try await gateway.client.from("events").update(EventUpdate(event)).eq("id", value: draft.id).select("id").execute()
            }
            if updated.isEmpty {
                try await gateway.client.from("events").insert(event).execute()
            }
            try await gateway.client.from("ticket_tiers").delete().eq("event_id", value: draft.id).execute()
            if !draft.isFree, !draft.tiers.isEmpty {
                let tiers = draft.tiers.enumerated().map { index, tier in
                    TierUpsert(id: tier.id, event_id: draft.id, name: tier.name, description: tier.description, price_minor: tier.price.minorUnits,
                               currency: "LKR", quantity: tier.quantity, max_per_order: tier.maxPerOrder, sales_start_at: tier.salesStartAt,
                               sales_end_at: tier.salesEndAt, sort_order: index)
                }
                try await gateway.client.from("ticket_tiers").insert(tiers).execute()
            }
            try await gateway.client.from("registration_questions").delete().eq("event_id", value: draft.id).execute()
            if !draft.questions.isEmpty {
                let questions = draft.questions.enumerated().map { index, question in
                    QuestionUpsert(id: question.id, event_id: draft.id, prompt: question.prompt, kind: question.kind.rawValue,
                                   options: question.options, required: question.required, sort_order: index)
                }
                try await gateway.client.from("registration_questions").insert(questions).execute()
            }
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
        return try await eventDraft(id: draft.id)
    }

    func eventDraft(id: UUID) async throws -> EventDraft {
        let row = try await gateway.decode(EventDraftRow.self) {
            try await gateway.client.from("events").select().eq("id", value: id).single().execute()
        }
        struct TierRow: Decodable {
            let id: UUID; let name: String; let description: String?; let priceMinor: Int64; let quantity: Int
            let maxPerOrder: Int?; let salesStartAt: Date?; let salesEndAt: Date?
        }
        struct QuestionRow: Decodable { let id: UUID; let prompt: String; let kind: QuestionKind; let options: [String]?; let required: Bool? }
        let tiers = try await gateway.decode([TierRow].self) {
            try await gateway.client.from("ticket_tiers").select().eq("event_id", value: id).order("sort_order").execute()
        }
        let questions = try await gateway.decode([QuestionRow].self) {
            try await gateway.client.from("registration_questions").select().eq("event_id", value: id).order("sort_order").execute()
        }
        var draft = EventDraft(id: row.id, organizerID: row.organizerId)
        draft.title = row.title
        draft.summary = row.summary ?? ""
        draft.description = row.description ?? ""
        draft.categoryID = row.categoryId
        draft.format = row.format
        draft.venueID = row.venueId
        draft.onlineURL = row.onlineUrl ?? ""
        draft.startsAt = row.startsAt
        draft.endsAt = row.endsAt
        draft.capacity = row.capacity
        draft.isFree = row.isFree
        draft.university = row.university ?? ""
        draft.tags = row.tags ?? []
        draft.coverPath = row.coverPath
        draft.coverAlt = row.coverAlt ?? ""
        draft.agenda = (row.agenda ?? []).map(\.domain)
        draft.speakers = (row.speakers ?? []).map(\.domain)
        draft.refundPolicy = row.refundPolicy ?? ""
        draft.registrationClosesAt = row.registrationClosesAt
        draft.status = row.status
        draft.creationFeePaid = row.creationFeePaidAt != nil
        draft.tiers = tiers.map {
            TierDraft(id: $0.id, name: $0.name, description: $0.description ?? "", price: .lkr($0.priceMinor), quantity: $0.quantity,
                      maxPerOrder: $0.maxPerOrder ?? 4, salesStartAt: $0.salesStartAt, salesEndAt: $0.salesEndAt)
        }
        draft.questions = questions.map { QuestionDraft(id: $0.id, prompt: $0.prompt, kind: $0.kind, options: $0.options ?? [], required: $0.required ?? false) }
        return draft
    }

    func uploadEventImage(eventID: UUID, organizerID: UUID, jpegData: Data) async throws -> String {
        let path = "\(organizerID.uuidString.lowercased())/\(eventID.uuidString.lowercased())/cover-\(Int(Date.now.timeIntervalSince1970)).jpg"
        do {
            try await gateway.client.storage.from(StorageBucket.eventMedia)
                .upload(path, data: jpegData, options: FileOptions(cacheControl: "86400", contentType: "image/jpeg", upsert: true))
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
        return path
    }

    func submitForPublish(eventID: UUID) async throws {
        try await gateway.rpc("submit_event_for_publish", EventIDParam(p_event_id: eventID))
    }

    func stats(eventID: UUID) async throws -> OrganizerEventStats {
        try await gateway.rpc("organizer_event_stats", EventIDParam(p_event_id: eventID), as: EventStatsRow.self).domain
    }

    func attendees(eventID: UUID) async throws -> [AttendeeRow] {
        try await gateway.rpc("organizer_attendees", EventIDParam(p_event_id: eventID), as: [AttendeeRowDTO].self).map(\.domain)
    }

    func settlements() async throws -> [SettlementRow] {
        try await gateway.rpc("organizer_settlements", NoParams(), as: [SettlementRowDTO].self).map(\.domain)
    }

    func sendUpdate(eventID: UUID, kind: EventUpdateKind, message: String) async throws -> Int {
        struct Params: Encodable, Sendable { let p_event_id: UUID; let p_kind: String; let p_message: String }
        return try await gateway.rpc("send_event_update", Params(p_event_id: eventID, p_kind: kind.rawValue, p_message: message), as: Int.self)
    }

    func exportAttendees(eventID: UUID) async throws -> ExportedFile {
        struct Body: Encodable, Sendable { let event_id: UUID }
        struct Response: Decodable { let filename: String; let csv: String }
        let response = try await gateway.invoke("organizer-export", body: Body(event_id: eventID), as: Response.self)
        return ExportedFile(filename: response.filename, contents: response.csv)
    }

    func generateDraft(eventID: UUID, kind: AIDraftKind, instructions: String?) async throws -> AIDraftResult {
        struct Body: Encodable, Sendable { let event_id: UUID; let kind: String; let instructions: String?; let request_id: String }
        return try await gateway.invoke(
            aiFunctionName,
            body: Body(event_id: eventID, kind: kind.rawValue, instructions: instructions, request_id: IdempotencyKey.make(prefix: "ai")),
            as: AIDraftResponse.self
        ).domain
    }

    func resolveDraft(id: UUID, approved: Bool) async throws {
        struct Update: Encodable, Sendable { let status: String }
        do {
            try await gateway.client.from("ai_drafts").update(Update(status: approved ? "approved" : "discarded")).eq("id", value: id).execute()
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
    }
}

// MARK: - Check-in

struct SupabaseCheckInRepository: CheckInRepository {
    let gateway: SupabaseGateway
    func checkIn(eventID: UUID, code: String) async throws -> CheckInOutcome {
        struct Params: Encodable, Sendable { let p_event_id: UUID; let p_code: String }
        return try await gateway.rpc("check_in_ticket", Params(p_event_id: eventID, p_code: code), as: CheckInRow.self).domain
    }
}

/// Live image source: public event media over the CDN, avatars through authenticated download.
struct SupabaseImageDataSource: ImageDataSource {
    let client: SupabaseClient
    let publicSource: URLImageDataSource

    func data(for reference: ImageReference) async throws -> Data {
        if case .storage(let bucket, let path) = reference, bucket == StorageBucket.avatars {
            return try await client.storage.from(bucket).download(path: path)
        }
        return try await publicSource.data(for: reference)
    }
}
