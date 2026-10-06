# Zuno – backend security

Scope: the Supabase database (`supabase/migrations`), Storage, Realtime and the Edge Functions
(`supabase/functions`). The guiding rule from the contract: **clients never write balances,
prices of published events, statuses, tickets, commission or ledger rows; identity and
verification status are server-owned.**

## 1. Privilege model

* Supabase grants ALL on new `public` objects to `anon`/`authenticated` by default. Migration
  `0100` revokes those defaults (tables, sequences, functions, and the global
  EXECUTE-to-PUBLIC default); every privilege a client has is granted explicitly in `0600`
  (tables, column-level for writes) and `1300` (functions).
* Server-owned columns are protected by **column-level grants**: e.g. `authenticated` may
  `UPDATE (display_name, avatar_path, city, district, preferred_categories, language,
  accessibility_needs, phone, onboarding_completed_at)` on `profiles` but has no privilege on
  `identity_status`; on `events` there is no INSERT/UPDATE privilege on `status`,
  `seats_taken`, `creation_fee_paid_at`, `published_at`, `cancelled_at`, timestamps or the
  search columns; on `ticket_tiers` none on `sold`/`reserved`.
* `service_role` (Edge Functions) keeps Supabase's table defaults **except**: no
  INSERT/UPDATE/DELETE/TRUNCATE on `wallets`, `wallet_ledger`, `audit_events`, and no access
  at all to `identity_digests`. Money and identity change only through definer functions.
* `private` schema: helpers and trigger functions. Not exposed by PostgREST (`config.toml`
  exposes only `public`, `graphql_public`); `anon`/`authenticated` can execute only the
  boolean predicates used inside RLS/storage policies and `private.fail`.
* Migration `1300` fails the deployment if any public table lacks RLS, any SECURITY DEFINER
  function lacks `search_path=''`, any function is executable by PUBLIC, or `event_cards` is
  not `security_invoker`. The SQL suite re-checks these invariants.

## 2. RLS matrix

R = select, I = insert, U = update, D = delete; "own" = `user_id/id = auth.uid()`;
"owner" = the caller owns the event's organizer profile. `service_role` bypasses RLS
(BYPASSRLS) but is still bound by the grants above.

| Table / view | anon | authenticated | service_role (table grants) |
|---|---|---|---|
| `platform_settings`, `categories` | R | R | all |
| `profiles` | – | R/I/U own; I/U editable columns only | all |
| `user_identities` | – | R own | all |
| `identity_digests` | – | – | **none** (RPC `record_identity_digest` only) |
| `wallets` | – | R own | R only |
| `wallet_ledger` | – | R own (append-only) | R only |
| `allowance_usage` | – | – (via `wallet_summary`/`quote_free_registration`) | all |
| `notification_preferences` | – | R own; U own (boolean columns) | all |
| `notifications` | – | R own; read state only via `mark_*_read` RPCs | all |
| `push_devices` | – | R/I/D own | all |
| `organizer_profiles` | R verified: `id, name, slug, bio, logo_path` only | R verified + own (all columns); I own (`verification_status` stays `pending`); U own: `name, slug, bio, logo_path, contact_email` | all |
| `venues` | R (verified or own organizer) | R; I/U/D own organizer; U/D only while no non-draft event uses the venue | all |
| `events` | R `published` (no `online_url`, no search columns) | R published + own; I own as `draft`; U own while `draft` (non-server columns) | all |
| `event_cards` (view, security_invoker) | R published | R published + own | R |
| `ticket_tiers`, `registration_questions`, `event_media` | R of published events | R published + own; I/U/D own while event is `draft` (no `sold`/`reserved`) | all |
| `ai_drafts` | – | R own organizer; U `status` → `approved`/`discarded` only | all |
| `event_updates` | – | R own events | all |
| `saved_events` | – | R/I/D own (I only published events) | all |
| `saved_organizers` | – | R/I/D own (I only verified organizers) | all |
| `orders`, `order_items` | – | R own | all |
| `registrations`, `registration_answers`, `tickets`, `check_ins`, `payments`, `event_settlements`, `rate_limits` | – | – (RPCs only) | all |
| `audit_events` | – | – | R only (append-only) |
| `storage.objects` `event-media` | R | R; I/U/D only under `<organizer_id>/…` of an organizer the caller owns | bypass |
| `storage.objects` `avatars` | – | R; I/U/D only under `<auth.uid()>/…` | bypass |

Path rules are also enforced on the table side: `profiles.avatar_path` must start with
`<uid>/`; `events.cover_path`, `event_media.storage_path`, `organizer_profiles.logo_path` must
start with `<organizer_id>/` (the `seed/` prefix is accepted only from server-side writers that
carry no end-user JWT).

## 3. RPC surface

| Callable by | Functions |
|---|---|
| anon + authenticated | `search_events`, `get_event_detail` |
| authenticated | `quote_free_registration`, `register_for_free_event`, `join_waitlist`, `cancel_registration`, `my_tickets`, `my_registrations`, `wallet_summary`, `mark_notifications_read`, `mark_all_notifications_read`, `organizer_dashboard`, `organizer_event_stats`, `organizer_attendees`, `organizer_settlements`, `submit_event_for_publish`, `send_event_update`, `cancel_event`, `check_in_ticket` |
| service_role only | `create_payment_order`, `apply_payhere_notification`, `expire_stale_orders`, `rate_limit_hit`, `record_identity_digest`, `prepare_account_deletion`, `organizer_export_data` |

### Definer-function hardening

* Every function is `SECURITY DEFINER` with `SET search_path = ''`; every relation, function
  and extension object is schema-qualified (`public.events`, `auth.uid()`,
  `extensions.gen_random_bytes`). Built-ins resolve from `pg_catalog` only.
* User identity comes from `auth.uid()` (JWT claims), never from parameters, for client RPCs.
  Service-only RPCs take `p_user_id` from an Edge Function that has already validated the JWT
  with `auth.getUser`.
* Authorisation is checked inside each function (`not_owner`, `not_authorized`, …); unknown
  events report `not_owner` to organizers so existence is not leaked.
* Errors are `RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = '<code>'` — no internal
  details; the Edge layer maps unknown errors to `500 internal_error`.
* **Locking order**: the `events` row `FOR UPDATE` is always taken first; rows belonging to one
  event are only locked under that lock; shared rows (`wallets` in ascending `user_id`, then
  `allowance_usage`) come last. Proven with two real concurrent sessions in
  `tests/110_concurrency.sql` (last-seat race, concurrent idempotent replay, double scan).
* **Idempotency**: `register_for_free_event` (key re-checked after each lock), orders
  (`unique(user_id, idempotency_key)`), PayHere notifications (`unique(provider_payment_id,
  status_code)`), AI drafts (`unique(event_id, request_id)`).
* **Money integrity**: wallet balances change only when a `posted` ledger row is inserted or a
  `pending` row becomes `posted` (trigger `private.wallet_ledger_apply`, which locks the wallet
  row and raises `insufficient_balance` before going negative); the wallets guard rejects any
  other balance change; `CHECK (balance_minor >= 0)`; ledger rows cannot be updated (except
  pending → posted/failed by definer functions and user_id → NULL on account deletion),
  deleted or truncated — even by the table owner. `audit_events` is append-only the same way.
* **Inventory integrity**: `CHECK (sold + reserved <= quantity)` on tiers,
  `CHECK (seats_taken <= capacity)` on events, unique active registration per (event, user),
  unique `check_ins.ticket_id`, single-use check-in via `UPDATE … WHERE status = 'valid'`.

## 4. Edge Functions

* `verify_jwt = true` for user-facing functions **and** `auth.getUser(jwt)` inside the function.
  `payhere-notify` trusts only a valid `md5sig` (constant-time compare) + merchant id; amount
  and currency are re-checked against the order in SQL. `payhere-return` only redirects.
  `push-dispatch` requires the service-role key (constant-time compare).
* Request bodies are size-limited and strictly validated (UUIDs, enums, integer amounts);
  prices are never accepted from clients (top-up amount is bounded by platform settings).
* Rate limits: see `SUPABASE_SETUP.md` §8.
* AI co-pilot: organizer ownership is checked before any model call; event text is passed as
  data inside `<event>` tags; output is schema-constrained and re-validated (lengths, kinds,
  offsets within the event); drafts are suggestions only (never written to events by the server).
* CSV export neutralises spreadsheet formulas (`=`, `+`, `-`, `@` prefixes) and quotes per RFC 4180.

## 5. Secret inventory

| Secret | Where | Notes |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | injected into Edge Functions; `seed-storage.sh` env | bypasses RLS — server only, never in the app |
| `NIC_HMAC_KEY`, `NIC_HMAC_KEY_VERSION` | Edge secret | ≥ 32 random bytes. Rotation changes every digest; plan: add `v2`, re-verify users lazily (new digests stored with `key_version = 2`), keep v1 until migrated. Raw NICs are never stored, so old digests cannot be re-computed server-side. |
| `PAYHERE_MERCHANT_ID`, `PAYHERE_MERCHANT_SECRET` | Edge secret | sandbox and live differ |
| `ANTHROPIC_API_KEY` (+ `AI_MODEL`, `AI_EFFORT`, `AI_FALLBACKS`) | Edge secret | |
| `APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`, `APNS_ENV` | Edge secret | token-based APNs auth |
| Apple / Google OAuth client secrets | Auth provider settings (`env(...)` in `config.toml`) | Apple secret JWT expires ≤ 6 months |
| Database password | dashboard / CLI link | |

`supabase/functions/.env.example` lists every variable with placeholders only;
`supabase/.gitignore` ignores `.env` files. The seed uses the documented placeholder password
`change-me-locally` for `.example` accounts, local only.

## 6. Logging rules

`_shared/log.ts` writes one JSON line per event and **redacts recursively** any field whose key
matches `authorization|token|secret|password|nic|digest|card|md5sig|hash|answer(s)|phone|email|apikey|private|p8|cookie|signature`.
Functions log ids and outcomes (user id, order id, status codes, counts), never request bodies.
`nic-digest` logs only the status; `payhere-notify` logs order id, status code and outcome;
the SQL audit trail (`audit_events`) records actions without NIC digests, answers or card data.

## 7. Personal data

* NIC: only `HMAC-SHA-256(NIC_HMAC_KEY, canonical NIC)`; old 9-digit+V/X numbers are
  canonicalised to 12 digits first so both spellings collide. No client access to digests.
* Registration answers: readable only by the organizer through `organizer-export`; deleted on
  account deletion.
* `organizer_attendees` exposes names, tier, status, check-in time and reference — no e-mail,
  phone, answers or NIC data.
* Account deletion (`delete-account` → `auth.admin.deleteUser`): the BEFORE DELETE trigger
  cancels pending orders and future registrations (seats passed to the waitlist), deletes
  answers, removes names from tickets, detaches ledger/orders/payments/registrations/audit rows
  from the person (`user_id = NULL`) and suspends/detaches owned organizer profiles; profile,
  wallet, notifications, devices, identities and the identity digest are deleted by cascade.
  Storage under `avatars/<uid>/` and `event-media/<organizer_id>/` is removed first.

## 8. Remaining assumptions / risks

* Authenticated users can read every column of **verified** organizer profiles, including
  `contact_email` (treated as the organizer's public business contact). Anonymous users get
  only the public columns. RLS is row-level; hiding the column from signed-in users would break
  the owner's own `select=*` / `insert … returning`.
* `events.online_url` of published events is readable by any signed-in user directly from the
  table (needed for the organizer's own `returning *`); `get_event_detail` only discloses it to
  confirmed attendees and the organizer. Use per-attendee or waiting-room links for sensitive
  online events.
* `push_devices.apns_token` is globally unique: a device that changes account must delete its
  token on sign-out before the next user registers it.
* Account deletion forfeits the wallet balance and paid tickets (there is no withdrawal
  feature); the app must warn the user. Organizers with live events must cancel or finish them first.
* Card refunds are manual in the PayHere portal; Zuno automates wallet refunds only.
* `rate_limit_hit` increments are rolled back when the calling transaction fails, so failed
  attempts that raise (e.g. `not_authorized` check-ins) are not counted or audited in the
  database; Edge Function logs still record them.
* Supabase-specific behaviour (PostgREST, GoTrue triggers, Storage policy enforcement,
  Realtime RLS, pg_cron) was emulated with stubs, not exercised on a hosted project
  (see `VERIFICATION.md`).
