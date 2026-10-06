# Zuno Backend Contract (v1)

This is the shared contract between the Supabase backend (`supabase/`) and every client
(iOS today; web and Android later). Clients must only depend on what is listed here.
All names are `snake_case`. All timestamps are `timestamptz` serialised as ISO-8601 with
offset. All money is **integer minor units** (`bigint`, LKR cents) with a `currency` of `'LKR'`.
The business time zone is `Asia/Colombo` (UTC+05:30, no DST).

## 1. Platform settings (`public.platform_settings`, read-only to clients)

| key | default | meaning |
|---|---|---|
| `free_allowance_per_month` | `15` | free-event registrations included per user per calendar month (Asia/Colombo) |
| `extra_free_registration_fee_minor` | `250` | wallet deduction for each free registration beyond the allowance. Check constraint keeps it within 250–300 (LKR 2.50–3.00) |
| `commission_bps` | `500` | platform commission on paid tickets, basis points, deducted from the organizer settlement (the attendee pays face value) |
| `event_creation_fee_minor` | `100000` | LKR 1,000.00 organizer fee per published event |
| `wallet_topup_min_minor` / `wallet_topup_max_minor` | `10000` / `5000000` | top-up bounds |
| `order_hold_minutes` | `15` | inventory reservation lifetime for pending ticket orders |

Commission rounding: `commission_minor = (subtotal_minor * commission_bps + 5000) / 10000` (integer division, half-up).

## 2. Client-readable relations

All tables have RLS enabled. Clients never write balances, prices, statuses, tickets or ledger rows.

### `categories` (public read)
`id text pk` (slug), `name text`, `symbol_name text` (SF Symbol), `sort_order int`.
Slugs: `hackathons, technology, workshops, university, art, music, sports, culture, careers, community`.

### `event_cards` view (`security_invoker = true`, published events only for non-owners)
| column | type |
|---|---|
| `id` | uuid |
| `title`, `summary` | text |
| `category_id`, `category_name` | text |
| `organizer_id` | uuid |
| `organizer_name` | text |
| `venue_name`, `city`, `district` | text (nullable for online) |
| `latitude`, `longitude` | double precision (nullable) |
| `university` | text nullable |
| `format` | `'physical' \| 'online' \| 'hybrid'` |
| `starts_at`, `ends_at` | timestamptz |
| `is_free` | boolean |
| `min_price_minor` | bigint nullable (null when free) |
| `currency` | text |
| `capacity`, `seats_taken`, `seats_remaining` | int |
| `cover_path`, `cover_alt` | text nullable (`cover_path` is a path inside the `event-media` bucket) |
| `tags` | text[] |
| `status` | `'draft' \| 'pending_review' \| 'published' \| 'cancelled' \| 'completed'` |
| `published_at` | timestamptz nullable |

### `saved_events` (own rows: select / insert / delete)
`user_id uuid` (defaults to `auth.uid()`), `event_id uuid`, `created_at`. PK `(user_id, event_id)`.

### `saved_organizers` (own rows: select / insert / delete)
`user_id uuid` default `auth.uid()`, `organizer_id uuid`, `created_at`.

### `profiles` (own row: select / insert / update of the editable columns only)
`id uuid` (= `auth.users.id`), `display_name text`, `avatar_path text` (path in `avatars` bucket),
`city text`, `district text`, `preferred_categories text[]`, `language text` (`en|si|ta`),
`accessibility_needs text[]` (`wheelchair_access, sign_language, quiet_space, large_print, assisted_entry`),
`phone text` nullable, `identity_status text` (`none|verified_unique|duplicate`) **server-owned**,
`onboarding_completed_at timestamptz`, `created_at`, `updated_at`.
A trigger creates the row (and a `wallets` row and `notification_preferences` row) when an
`auth.users` row is created.

### `user_identities` (own rows: select)
Server-maintained mirror of linked providers: `id uuid`, `user_id`, `provider text`, `linked_at`, `unlinked_at`.

### `wallets` (own row: select)
`user_id uuid pk`, `balance_minor bigint`, `currency text`, `updated_at`.

### `wallet_ledger` (own rows: select; append-only)
`id uuid`, `user_id uuid`, `entry_type text` (`topup | free_registration_fee | refund_credit | ticket_purchase | adjustment`),
`amount_minor bigint` (signed: credits positive, debits negative), `balance_after_minor bigint` nullable (null while pending),
`status text` (`pending | posted | failed`), `reference_type text`, `reference_id uuid`, `description text`, `created_at`.

### `orders` (own rows: select)
`id uuid`, `user_id`, `event_id` nullable, `kind` (`ticket | wallet_topup | event_creation_fee`),
`status` (`pending | paid | failed | cancelled | expired | refunded`), `subtotal_minor`, `commission_minor`,
`total_minor`, `currency`, `expires_at`, `paid_at`, `created_at`, `updated_at`.

### `order_items` (rows of own orders: select)
`id`, `order_id`, `tier_id`, `quantity int`, `unit_price_minor`.

### `notifications` (own rows: select; read state changes only through RPCs)
`id uuid`, `user_id`, `kind text` (`registration_confirmed | payment_status | ticket_issued | event_reminder | venue_change | schedule_change | event_cancelled | refund_status | waitlist_movement | organizer_update | general`),
`title text`, `body text`, `event_id uuid` nullable, `data jsonb`, `read_at timestamptz` nullable, `created_at`.

### `notification_preferences` (own row: select / update)
`user_id pk`, `event_reminders bool`, `payment_updates bool`, `event_changes bool`, `waitlist_updates bool`, `organizer_news bool`, `push_enabled bool`, `updated_at`.

### `push_devices` (own rows: select / insert / delete)
`id`, `user_id` default `auth.uid()`, `apns_token text unique`, `environment text` (`sandbox|production`), `created_at`, `updated_at`.

### Organizer tables (owner of the organizer profile)
- `organizer_profiles`: `id`, `owner_id` (default `auth.uid()`, unique), `name`, `slug` unique, `bio`, `logo_path`, `contact_email`, `verification_status` (`pending|verified|rejected|suspended`, **server-owned**), `created_at`, `updated_at`. Public can read verified profiles' `id, name, slug, bio, logo_path`.
- `venues`: `id`, `organizer_id`, `name`, `address_line`, `city`, `district`, `latitude`, `longitude`, `created_at`.
- `events`: `id`, `organizer_id`, `category_id`, `venue_id` nullable, `title`, `summary`, `description`, `format`, `starts_at`, `ends_at`, `timezone` (default `Asia/Colombo`), `capacity`, `is_free`, `university`, `tags text[]`, `cover_path`, `cover_alt`, `agenda jsonb`, `speakers jsonb`, `refund_policy`, `registration_opens_at`, `registration_closes_at`, `online_url` nullable; server-owned: `status`, `seats_taken`, `creation_fee_paid_at`, `published_at`, `created_at`, `updated_at`. Organizers may insert/update their own events only while `status = 'draft'`.
- `ticket_tiers`: `id`, `event_id`, `name`, `description`, `price_minor`, `currency`, `quantity`, `max_per_order`, `sales_start_at`, `sales_end_at`, `sort_order`; server-owned `sold`, `reserved`. Organizer CRUD while event is a draft.
- `registration_questions`: `id`, `event_id`, `prompt`, `kind` (`short_text|long_text|single_choice|multi_choice|yes_no`), `options jsonb` (array of strings), `required bool`, `sort_order`. Organizer CRUD while draft.
- `event_media`: `id`, `event_id`, `storage_path`, `kind` (`cover|gallery`), `alt_text`, `width`, `height`, `sort_order`.
- `ai_drafts`: organizer select/update `status` to `approved|discarded` only.
- `event_updates`: organizer select; created through `send_event_update`.

`agenda` JSON: `[{"starts_at": "...", "ends_at": "...", "title": "...", "detail": "..." }]`.
`speakers` JSON: `[{"name": "...", "role": "...", "organization": "..."}]`.

## 3. RPC functions (PostgREST `rpc/<name>`, `security definer`, `search_path = ''`)

Errors are raised with `RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '<code>'` where `<code>` is one of the
machine codes listed per function. Clients map codes to localized copy.

### `search_events(p_query text default null, p_filters jsonb default '{}', p_limit int default 50, p_offset int default 0) returns setof event_cards`
`p_filters` keys (all optional): `date_from`, `date_to` (ISO timestamps), `cities text[]`, `districts text[]`,
`near_lat`, `near_lng`, `radius_km` (haversine), `price` (`free|paid`), `format` (`physical|online`; `online` also matches `hybrid`),
`available_only bool`, `organizer_ids uuid[]`, `category_ids text[]`, `university text`.
Text matching covers title, summary, description, organizer name, category name, venue name, city, district, university, tags.
Only `published` events that have not ended are returned, ordered by `starts_at`.

### `get_event_detail(p_event_id uuid) returns jsonb`
```json
{
  "event": { /* event_cards columns */ "description": "...", "agenda": [], "speakers": [], "refund_policy": "...",
             "registration_opens_at": null, "registration_closes_at": "...", "online_url": null,
             "address_line": "...", "organizer_slug": "...", "organizer_verified": true },
  "tiers": [{ "id": "...", "name": "General", "description": "...", "price_minor": 150000, "currency": "LKR",
              "quantity": 200, "remaining": 120, "max_per_order": 4, "sales_start_at": null, "sales_end_at": "...", "on_sale": true }],
  "questions": [{ "id": "...", "prompt": "...", "kind": "single_choice", "options": ["A","B"], "required": true }],
  "media": [{ "storage_path": "...", "kind": "gallery", "alt_text": "..." }],
  "viewer": { "is_saved": false, "registration_status": null, "registration_id": null, "waitlisted": false, "is_organizer": false }
}
```
Errors: `event_not_found`.

### `quote_free_registration(p_event_id uuid) returns jsonb`
```json
{ "allowance_limit": 15, "allowance_used": 15, "allowance_remaining": 0, "fee_minor": 250,
  "wallet_balance_minor": 14000, "currency": "LKR", "can_register": true, "reason": null,
  "seats_remaining": 12, "month": "2026-10" }
```
`reason` (when `can_register = false`): `already_registered | sold_out | registration_closed | insufficient_balance | identity_required | not_free_event`.

### `register_for_free_event(p_event_id uuid, p_answers jsonb, p_expected_fee_minor bigint, p_idempotency_key text) returns jsonb`
Atomic: locks the event and wallet rows, re-validates window, duplicate, capacity, allowance, identity, required answers;
debits the wallet (ledger `free_registration_fee`) only when the allowance is exhausted; creates the registration,
answers and ticket; increments `seats_taken`; writes a notification and an audit event. Any failure rolls everything back.
`p_expected_fee_minor` must equal the server's computed fee (otherwise `fee_changed`), proving the user confirmed the exact deduction.
Replaying the same `p_idempotency_key` returns the original result.
```json
{ "registration_id": "...", "reference": "ZR-7K2M9QXA", "ticket_id": "...", "fee_minor": 0,
  "allowance_remaining": 11, "wallet_balance_minor": 14000, "status": "confirmed" }
```
`p_answers`: `[{"question_id": "...", "value": "text" | ["choice"] | true}]`.
Errors: `event_not_found | not_free_event | registration_closed | already_registered | sold_out | insufficient_balance | fee_changed | identity_required | answers_invalid | not_authenticated`.

### `join_waitlist(p_event_id uuid) returns jsonb` → `{ "registration_id": "...", "status": "waitlisted", "position": 3 }`
### `cancel_registration(p_registration_id uuid) returns jsonb` → `{ "status": "cancelled" }` (frees the seat, cancels the ticket, offers the seat to the next waitlisted user via a `waitlist_movement` notification)

### `my_tickets() returns jsonb`
```json
[{ "ticket_id": "...", "code": "ZN-4K7P-Q2MX", "qr_payload": "zuno:t:<token>", "status": "valid",
   "tier_name": "General", "attendee_name": "...", "issued_at": "...", "checked_in_at": null,
   "registration_reference": "ZR-...", "order_id": null,
   "event": { "id": "...", "title": "...", "starts_at": "...", "ends_at": "...", "venue_name": "...", "city": "...",
              "cover_path": "...", "cover_alt": "...", "status": "published", "category_id": "tech" } }]
```
Ticket `status`: `valid | checked_in | cancelled | refunded`.

### `my_registrations() returns jsonb` — registration history incl. waitlisted/cancelled with the same `event` object, `status`, `kind`, `fee_minor`, `reference`, `created_at`.

### `wallet_summary() returns jsonb`
`{ "balance_minor": 14000, "currency": "LKR", "allowance_limit": 15, "allowance_used": 4, "allowance_remaining": 11, "extra_fee_minor": 250, "month": "2026-10", "pending_topups_minor": 0 }`

### `mark_notifications_read(p_ids uuid[]) returns int` / `mark_all_notifications_read() returns int`

### Organizer RPCs (caller must own the organizer profile of the event)
- `organizer_dashboard() returns jsonb` → `{ "organizer": {...}, "events": [event_cards + "registrations": n, "checked_in": n], "totals": { "gross_minor", "commission_minor", "net_minor" } }`
- `organizer_event_stats(p_event_id uuid) returns jsonb` → `{ "capacity", "registrations", "waitlisted", "checked_in", "tickets_sold", "gross_minor", "commission_minor", "net_minor", "by_tier": [{ "tier_id","name","sold","quantity","gross_minor" }] }`
- `organizer_attendees(p_event_id uuid) returns jsonb` → `[{ "ticket_id", "attendee_name", "tier_name", "status", "checked_in_at", "registration_reference" }]` (no emails, no NIC data; answers only via export)
- `organizer_settlements() returns jsonb` → per event gross/commission/net and payout status (`unsettled|scheduled|paid`).
- `submit_event_for_publish(p_event_id uuid) returns jsonb` → validates (title, summary ≥ 20 chars, future start, end after start, capacity > 0, cover, venue or online URL, at least one on-sale tier for paid events, organizer `verified`, creation fee paid) and publishes. Errors: `organizer_not_verified | creation_fee_unpaid | validation_failed` (with `DETAIL` listing fields) `| not_owner`.
- `send_event_update(p_event_id uuid, p_kind text, p_message text) returns int` — fans out notifications to confirmed registrants; `p_kind`: `venue_change | schedule_change | general`.
- `cancel_event(p_event_id uuid, p_reason text) returns jsonb` — cancels tickets, credits refunds (`refund_credit`) for wallet fees and paid tickets, notifies.
- `check_in_ticket(p_event_id uuid, p_code text) returns jsonb` → `{ "result": "valid|already_used|invalid|refunded|cancelled|wrong_event", "attendee_name": "...", "tier_name": "...", "checked_in_at": "..." }`. `p_code` accepts the QR payload (`zuno:t:<token>`) or the manual code (case/dash-insensitive). Atomic single-use transition `valid → checked_in`. Attempts are audited and rate-limited (`rate_limited`). Caller must be the event's organizer (`not_authorized`).

## 4. Edge Functions (`/functions/v1/<name>`)

All require `Authorization: Bearer <user access token>` except `payhere-notify`. JSON in, JSON out.
Errors: HTTP 4xx/5xx with `{ "error": "<code>", "message": "..." }`.

| function | request | response |
|---|---|---|
| `nic-digest` | `{ "nic": "200012345678" }` | `{ "status": "verified_unique" \| "duplicate" }`. Errors: `invalid_format`, `rate_limited`. Raw NIC never stored or logged; HMAC-SHA-256 with `NIC_HMAC_KEY`. Old 9+V/X format is canonicalised to the 12-digit form before hashing. |
| `payhere-checkout` | `{ "kind": "ticket", "event_id": "...", "items": [{ "tier_id": "...", "quantity": 2 }], "answers": [...], "phone": "+94771234567", "idempotency_key": "..." }` or `{ "kind": "wallet_topup", "amount_minor": 100000, "phone": "...", "idempotency_key": "..." }` or `{ "kind": "event_creation_fee", "event_id": "...", "phone": "...", "idempotency_key": "..." }` | `{ "order_id", "status": "pending", "expires_at", "summary": { "lines": [{ "label", "quantity", "unit_price_minor", "amount_minor" }], "subtotal_minor", "commission_minor", "total_minor", "currency" }, "checkout": { "action_url", "method": "POST", "fields": { "merchant_id", "return_url", "cancel_url", "notify_url", "order_id", "items", "currency", "amount", "first_name", "last_name", "email", "phone", "address", "city", "country", "hash" } } }` |
| `payhere-notify` | PayHere form POST (`merchant_id, order_id, payment_id, payhere_amount, payhere_currency, status_code, md5sig, ...`) | `200 ok`. Verifies `md5sig`, amount and currency against the order, applies idempotently (duplicate callbacks are no-ops), issues tickets / posts top-ups / marks creation fees only after verification. |
| `payhere-return` | GET from PayHere browser redirect | 302 to `zuno://payments/return?order_id=...` (informational only; never treated as proof of payment). |
| `ai-organizer-copilot` | `{ "event_id": "...", "kind": "agenda" \| "questions", "instructions": "optional", "request_id": "..." }` | `{ "draft_id", "kind", "status": "succeeded", "agenda": [...] }` or `{ ..., "questions": [...] }`. Errors: `not_owner`, `rate_limited`, `ai_timeout`, `ai_refused`, `ai_malformed`, `ai_unavailable`. |
| `delete-account` | `{ "confirm": "DELETE" }` | `{ "status": "deleted" }` — anonymises retained financial records, removes storage objects, deletes the auth user with the Admin API. |
| `organizer-export` | `{ "event_id": "..." }` | `{ "filename": "...csv", "csv": "..." }` — authorized organizers only; columns: reference, attendee name, tier, status, checked-in time, answers to organizer questions. |
| `push-dispatch` | service-role only `{ "user_ids": [...], "title", "body", "data" }` | APNs fan-out (credential-dependent). |

## 5. Storage

| bucket | public | write policy |
|---|---|---|
| `event-media` | read: public | insert/update/delete only under `<organizer_id>/...` by that organizer's owner |
| `avatars` | read: authenticated | insert/update/delete only under `<auth.uid()>/...` |

Max sizes: event media 8 MB (`image/jpeg, image/png, image/heic, image/webp`), avatars 3 MB.

## 6. Realtime

Publication `supabase_realtime` includes `notifications`, `orders`, `wallet_ledger` (RLS applies).

## 7. QR payloads and codes

- QR payload: `zuno:t:<token>` where `<token>` is 32 random bytes, base64url without padding (43 chars).
- Manual ticket code: `ZN-XXXX-XXXX` (Crockford base32, no I/L/O/U).
- Registration reference: `ZR-XXXXXXXX`.
