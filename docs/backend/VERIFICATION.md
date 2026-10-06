# Zuno backend – verification report

Date: 2026-10-06. **Read this first:** everything below ran on a developer machine against
**vanilla PostgreSQL 17.6 with Supabase stubs** (`supabase/tests/support/supabase_stubs.sql`)
and **Deno 2.9.7** — not against a hosted Supabase project and not through PostgREST, GoTrue,
Storage API, Realtime or the Edge Runtime. **No PayHere, Apple, Google, Anthropic or APNs call
was made against a real service**; those integrations were tested with injected fakes and
independently computed vectors only.

## 1. Commands and results

Tools: portable PostgreSQL 17.6 (`initdb`, `pg_ctl`, `postgres` only — no `psql`, so the
harness uses the bundled stdlib client `supabase/tests/support/pgwire.py`), Python 3.9.6,
Deno 2.9.7. Paths below are the session scratch directory used for the run.

### 1.1 Seed generation

```
$ python3 scripts/generate-seed-sql.py
wrote supabase/seed.sql (16 events, 5 organizers, 14 venues)
$ python3 scripts/generate-seed-sql.py --check
seed.sql is up to date
```

(14 venues = 13 from the JSON + 1 per-organizer copy, see clarification 12.)

### 1.2 Database: migrations + seed + SQL assertion suites

```
$ PG_BIN=<scratchpad>/tools/pg/bin ZUNO_VERIFY_DIR=<scratchpad>/pgdata/verify ./scripts/db-verify.sh
== Zuno database verification (vanilla PostgreSQL + Supabase stubs)
   postgres: postgres (PostgreSQL) 17.6
   client:   supabase/tests/support/pgwire.py
-- setup
   applied tests/support/supabase_stubs.sql
   applied migrations/20261006000100_extensions_and_privileges.sql
   ... (all 13 migrations applied, including the 1300 hardening self-checks)
   seed.sql is in sync with supabase/seed/zuno_seed.json
   applied seed.sql
   applied tests/support/test_helpers.sql
-- tests
   ok   001_schema_and_seed.sql            51 assertions passed
   ok   010_rls_isolation.sql              80 assertions passed
   ok   020_free_registration.sql          83 assertions passed
   ok   030_waitlist.sql                   35 assertions passed
   ok   040_payments.sql                   99 assertions passed
   ok   050_check_in.sql                   27 assertions passed
   ok   060_organizer.sql                  66 assertions passed
   ok   070_ledger_guards.sql              25 assertions passed
   ok   080_storage_policies.sql           16 assertions passed
   ok   090_account_identity.sql           28 assertions passed
   ok   100_search_and_detail.sql          73 assertions passed
   ok   110_concurrency.sql                11 assertions passed
-- summary
   migrations applied: 13
   assertions passed:  594
   failing test files: 0
RESULT: PASS
```

Run twice back to back on fresh clusters with identical results (594/594). The harness was
also observed to fail correctly (exit 1, failing assertion printed) while the suites were
being developed.

### 1.3 Edge Functions

```
$ DENO=<scratchpad>/deno DENO_DIR=<scratchpad>/deno_cache ./scripts/functions-check.sh
== deno 2.9.7
-- deno check (27 modules)
-- deno test
...
ok | 64 passed | 0 failed
RESULT: PASS
$ (cd supabase/functions && deno lint)        -> Checked 40 files, no findings
$ (cd supabase/functions && deno fmt --check) -> Checked 41 files, no findings
```

`deno check` covers every `*/index.ts`, `*/handler.ts` and `_shared/*.ts` against
`npm:@supabase/supabase-js` (resolved to 2.117.2, pinned in `supabase/functions/deno.lock`)
and `jsr:@std/{crypto,encoding,assert}`.

### 1.4 Other checks

* `config.toml` parsed with `jsr:@std/toml` (project_id `zuno`, 8 functions,
  `payhere-notify.verify_jwt = false`, redirect URLs, e-mail confirmations, Apple/Google enabled).
* `bash -n` on `db-verify.sh`, `functions-check.sh`, `seed-storage.sh`.
* `scripts/seed-storage.sh` against a local mock of the Storage REST endpoint
  (`SUPABASE_URL=http://127.0.0.1:54399`): `16 uploaded, 0 failed`; the mock asserted the
  bearer key, `x-upsert: true`, the `event-media/seed/<slug>.jpg` path and JPEG bodies.

## 2. What the suites cover

| Area | Where | Highlights |
|---|---|---|
| Hardening invariants | 001 | RLS on every table, definer `search_path=''`, no PUBLIC execute, column privileges (identity/verification/status/seats/sold/reserved), service-role-only RPCs, anon surface, identity_digests closed to every API role, Realtime publication, buckets, 250–300 fee constraint |
| Seed integrity | 001, 100 | 16 events, Colombo-local dates/offsets, agenda timestamps, dev wallet = ledger (14000), allowance 13, 4 tickets, contract code formats, paid seats = sold |
| RLS isolation | 010 | user A vs B on wallets, ledger, orders, order items, notifications, profiles, devices, saved events; tickets/registrations/payments not readable; client writes to balances/statuses/prices/identity rejected; anon sees published only, no `online_url`/`contact_email`; organizer draft-only editing; AI draft review; service role cannot write wallets |
| Free registration | 020 | 15 real free registrations then fee; `fee_changed` (missing/old fee, fee raised to 300); insufficient balance leaves no registration/ledger/ticket/seat/allowance change; duplicates; idempotent replay + `idempotency_conflict`; capacity; identity; window rules (single-session closes at start, multi-day open until end); answers validation and normalisation; monthly reset |
| Waitlist | 030 | positions, `seats_available`, offer on cancellation with held seat, offered user confirms without double counting, expiry via `expire_stale_orders` and lazily under the event lock |
| Payments | 040 | DB pricing (client amount ignored), commission half-up (30→2, 29→1, 9→0, 90→5), reservations, replay, sold-out/max-per-order/invalid items/capacity across tiers, amount & currency mismatch rejected, tickets only after verified success, duplicate callback no-op, no downgrade of paid orders, failed/cancelled/expired release holds, late success fulfilled or refunded, top-ups pending→posted, failed top-ups, creation fee + duplicate fee refund, chargeback |
| Check-in | 050 | valid → already_used (QR and manual code, case/dash/space/alias tolerant), wrong_event, invalid, cancelled, refunded, not_authorized (other organizer, attendee), anon denied, audit rows, rate limit after 120/min |
| Organizer | 060 | publish validation with DETAIL field list, fee unpaid, unverified organizer, paid events need an on-sale tier, updates fan-out + rate limit, dashboard/stats/attendees/settlements/export data, `cancel_event` refunds fees and paid orders, restores allowance, cancels pending checkouts, late payment for cancelled event refunded |
| Ledger guards | 070 | append-only ledger and audit log (update/delete/truncate), wallet balance only via ledger, overdraft impossible, sign constraints, pending→posted only through the definer path |
| Storage | 080 | organizer folder ownership in `event-media`, `seed/` closed to clients, avatar folders, anon read rules, path checks on profile/event columns |
| Identity & deletion | 090 | digest uniqueness → `duplicate`, idempotent re-submit, `already_verified`, identity mirror link/unlink, account deletion anonymisation with seat hand-over to the waitlist |
| Search & reads | 100 | text over title/description/tags/organizer/category/venue/city/university, every filter, LIKE escaping, ordering/paging, `get_event_detail` contract keys, viewer block, `my_tickets`/`my_registrations`/`wallet_summary` keys |
| Concurrency | 110 | two real sessions via `dblink`: last-seat race (B blocks on the event lock, then `sold_out`), concurrent same-key replay returns the original registration, concurrent double scan → one `valid`, one `already_used` |

## 3. Contract clarifications and deviations

Where the contract was silent or contradictory, the most secure reasonable interpretation was
implemented:

1. **AI structured output.** The brief asked for structured output by *forcing a tool call*.
   The default model `claude-opus-5-5` (like Claude Sonnet 5.5) rejects forced `tool_choice` (`any`/`tool`) with HTTP 400,
   so the request uses the schema-constrained response format
   (`output_config.format = {type: "json_schema", ...}`), `output_config.effort = "low"` (25 s
   budget) and server-side refusal fallbacks (`fallbacks: "default"`, header
   `anthropic-beta: server-side-fallback-2026-07-01`; disable with `AI_FALLBACKS=off`). The
   output is still validated (`ai_malformed`), `stop_reason == "refusal"` → `ai_refused`, the
   25 s AbortController → `ai_timeout`; the parser also accepts a `tool_use` block.
   Effort/fallbacks are only sent for models known to support them.
2. **`create_payment_order`** has an extra trailing `p_answers jsonb default null` so paid
   events can collect required registration answers at checkout (validated then, written when
   payment is verified). `p_amount_minor` is used only for `wallet_topup`; ticket and
   creation-fee prices always come from the database.
3. **Identity requirement.** Free registrations (and joining a waitlist) require
   `identity_status = 'verified_unique'`; `none` and `duplicate` get `identity_required`. Paid
   tickets do not require identity verification.
4. **Allowance accounting.** Counted in `allowance_usage` per Asia/Colombo calendar month of
   the registration time. Attendee-initiated cancellations do not restore allowance or refund
   the extra fee; an organizer's `cancel_event` refunds fees (`refund_credit`) and restores
   allowance for that month.
5. **Seat accounting.** `seats_taken` counts confirmed registrations **plus active waitlist
   offers** (an offer holds a seat); for paid events it equals tickets sold. `seats_remaining`
   on paid events also subtracts live checkout reservations. The seed's paid events carry
   `seats_taken = 0` in the JSON; the seed sets them to the sum of tier `sold`.
6. **Waitlist.** Only for free events and only when full (`seats_available` otherwise).
   Offers last `min(12 h, registration close)`; expired offers are released lazily under the
   event lock and by `expire_stale_orders()`.
7. **Registration window default** (per coordinator note): when `registration_closes_at` is
   null, events longer than 24 h stay open until `ends_at`; single-session events close at
   `starts_at`. `get_event_detail.event.registration_closes_at` returns this *effective* close
   time, plus an extra boolean `registration_open`; tier `on_sale` uses the same rule.
8. **`cancel_registration`** (errors not listed in the contract): `registration_not_found`
   (not yours), `not_cancellable` (paid registrations – refunds go through the organizer /
   `cancel_event`), `already_checked_in`, `registration_closed` (event ended). Cancelling twice
   returns `{status: "cancelled"}`. Response also includes `registration_id`.
9. **Extra error codes**: `idempotency_conflict` (a key reused for another event/kind),
   `invalid_idempotency_key` (not 8–200 chars), `invalid_filters`/`invalid_query`
   (`search_events`), `seats_available` (`join_waitlist`), `invalid_kind`/`invalid_message`/
   `event_not_published` (`send_event_update`), `event_completed` (`cancel_event`);
   checkout: `invalid_phone`, `email_required`, `order_not_pending`, `payments_unavailable`,
   `invalid_items`, `tier_not_on_sale`, `max_per_order_exceeded`, `not_paid_event`,
   `invalid_amount`, `creation_fee_already_paid`, `event_not_editable`; `nic-digest`:
   `already_verified` (409); `delete-account`: `confirmation_required`,
   `organizer_has_active_events` (409).
10. **`get_event_detail`.** `online_url` is disclosed only to confirmed attendees and the
    organizer; attendees can still open cancelled/completed events they registered for;
    `viewer` has extra keys `waitlist_position` and `offer_expires_at`. Anon has no column
    privilege on `events.online_url`; signed-in users can read it from the table for published
    events (see SECURITY_BACKEND.md §8).
11. **`organizer_profiles` visibility.** Anon: verified profiles, `id, name, slug, bio,
    logo_path` only. Signed-in users: all columns of verified profiles (incl. `contact_email`,
    treated as a public business contact) and their own profile — required so the owner's
    `select *` / `insert … returning` works.
12. **Venues belong to one organizer.** An event may only use its organizer's venues
    (`venue_not_owned`), and venues used by non-draft events cannot be edited or deleted (venue
    changes go through `send_event_update('venue_change')`). The JSON points two Lanka OSS
    events at Colombo Builders' "Innovation Hall"; the generator gives Lanka OSS its own copy
    with a deterministic UUIDv5.
13. **Seed additions.** Online/hybrid events get `online_url = https://live.zuno.example/<slug>`;
    the already-ended event is seeded as `completed`; the development user's NIC status is
    `verified_unique` (no digest row); a cover `event_media` row per event; seed registrations
    include sample answers for required questions; the jazz ticket is one of the tier's seeded
    `sold` count. Category `hackathons` uses symbol `laptopcomputer` (updated JSON; the
    migration's canonical categories match).
14. **`search_events`.** `date_from`/`date_to` use overlap semantics (ongoing events match);
    `near_lat`/`near_lng` without `radius_km` default to 25 km; events without coordinates are
    excluded from radius searches; `format=physical` matches only physical (online matches
    hybrid, as specified); city/district matching is case-insensitive; `university` is a
    case-insensitive substring; `p_limit` is clamped to 1–100.
15. **Tickets.** Free tickets report `tier_name = "General admission"`; `qr_payload` is always
    present (cancelled/refunded tickets scan as such).
16. **Organizer RPC shapes.** `organizer_dashboard` returns `organizer: null` (and empty
    lists) for non-organizers; `organizer_settlements` returns an array of per-event objects
    (paid, non-draft events). Money totals come from paid orders, so seeded tier `sold` counts
    (which have no orders) do not appear as revenue.
17. **`check_in_ticket`** is limited to 120 attempts/minute per organizer. Ticket-level
    outcomes are audited; `not_authorized`/`rate_limited` raise and therefore roll back their
    own audit/counter rows.
18. **Event deletion** by organizers is not possible (the contract grants insert/update only);
    events are cancelled instead. `events.timezone` is constrained to `Asia/Colombo`.
19. **PayHere notification outcomes** beyond the contract (late payments, cancelled events,
    duplicate fees, chargebacks, deleted buyers) are documented in `PAYHERE_SETUP.md` §6; a
    verified amount/currency mismatch is recorded and answered with 400 `amount_mismatch`.
20. **Identity digests** are written by the service-role RPC `record_identity_digest` (atomic
    insert + profile status) instead of a direct table insert; a verified account cannot switch
    NIC (`already_verified`); digests are deleted with the account. NIC validation also rejects
    impossible day-of-year values (not 1–366 / 501–866) and years outside 1900…today.
21. **Account deletion** refuses organizers with live events, forfeits wallet balance and paid
    tickets, and anonymises in a BEFORE DELETE trigger on `auth.users` so every deletion path
    (Admin API, dashboard, SQL) is covered.
22. **`push-dispatch`** is deployed with `verify_jwt = false` and compares the bearer token with
    `SUPABASE_SERVICE_ROLE_KEY` in constant time (works with JWT and non-JWT secret keys); it
    also accepts Database Webhook payloads for `notifications` inserts and honours
    `notification_preferences`.
23. **`payhere-checkout`** sends `address = "N/A"`, `country = "Sri Lanka"`, the profile city
    (default Colombo) and splits `display_name` into first/last name; the e-mail comes from
    `auth.users` (or `PAYHERE_FALLBACK_EMAIL`). `return_url` carries `order_id`; `cancel_url`
    adds `cancelled=1`. Non-pending idempotent replays answer 409 `order_not_pending`.

## 4. Not verified (requires a hosted project or real credentials)

* Applying the migrations with `supabase db push` on a hosted project (owner/privilege details
  of `auth`, `storage`, `supabase_realtime`, `cron` differ from the stubs; e.g. whether the
  project allows `CREATE POLICY` on `storage.objects` and triggers on `auth.users`/`auth.identities`
  — both are documented Supabase patterns but were not exercised).
* PostgREST behaviour: JSON argument coercion for RPCs, `Prefer: return=representation` with
  column grants, error payload shape seen by the iOS client.
* GoTrue: `handle_new_user` on real sign-ups (e-mail, Apple, Google), identity linking/unlinking,
  `auth.admin.deleteUser` invoking the deletion trigger, redirect URLs.
* Storage API enforcement of the bucket size/MIME limits and the `storage.objects` policies;
  real uploads via `seed-storage.sh` (only a local mock was used).
* Realtime delivery and RLS filtering of `postgres_changes`.
* pg_cron scheduling (`cron` is not available in the portable build; the guarded block took
  the "not installed" branch).
* Edge Runtime deployment (bundling with `import_map = ./functions/deno.json`, `Deno.serve`),
  `auth.getUser` against GoTrue, and every external call: PayHere sandbox/live checkout and
  notifications, the Anthropic Messages API (model availability, `output_config`, fallbacks),
  APNs delivery with a real `.p8` key, Apple/Google OAuth.
* Load/performance characteristics (indexes exist for every hot path, but no load test ran).
* iOS client compatibility beyond the contract keys asserted in the suites.
