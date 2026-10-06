# Zuno – Supabase setup

This guide takes a new Supabase project from nothing to a running Zuno backend.
Everything the iOS app relies on is defined in `docs/BACKEND_CONTRACT.md`; the
implementation lives in `supabase/`.

```
supabase/
  config.toml                 CLI config (auth, storage, functions, redirect URLs)
  migrations/2026100600xx_*   schema, RLS, RPCs, storage, realtime, cron (apply in order)
  seed.sql                    LOCAL DEVELOPMENT ONLY sample data (generated)
  seed/zuno_seed.json         source of the seed data
  seed/images/<slug>.jpg      seed cover images (uploaded by scripts/seed-storage.sh)
  functions/                  Deno Edge Functions + deno.json import map + .env.example
  tests/                      SQL assertion suites + vanilla-Postgres Supabase stubs
scripts/
  db-verify.sh                throwaway-cluster verification of migrations + seed + tests
  functions-check.sh          deno check + deno test for all Edge Functions
  generate-seed-sql.py        zuno_seed.json -> supabase/seed.sql
  seed-storage.sh             uploads seed cover images to event-media/seed/
```

## 1. Prerequisites

* Supabase CLI 2.x (`brew install supabase/tap/supabase`), Docker for local work.
* Deno 2.x for `scripts/functions-check.sh`.
* Python 3.9+ (stdlib only) for the seed generator and `db-verify.sh`.

## 2. Local development

```bash
supabase start                                   # starts Postgres 17, Auth, Storage, Realtime, Studio
supabase db reset                                # applies migrations/*.sql then seed.sql
SUPABASE_URL=http://127.0.0.1:54321 \
SUPABASE_SERVICE_ROLE_KEY=<local service_role key from `supabase status`> \
  ./scripts/seed-storage.sh                      # uploads the 16 seed covers to event-media/seed/
cp supabase/functions/.env.example supabase/.env # fill in local test values
supabase functions serve --env-file supabase/.env
```

Seed accounts (LOCAL ONLY, password `change-me-locally`):
`dev.attendee@zuno.example` (attendee: LKR 140.00 wallet, 13/15 free registrations used,
4 tickets, 3 saved events) and `owner.<organizer-slug>@zuno.example` for each of the five
verified organizers. Never run `seed.sql` against production.

When `supabase/seed/zuno_seed.json` changes, regenerate the SQL:

```bash
python3 scripts/generate-seed-sql.py          # writes supabase/seed.sql
python3 scripts/generate-seed-sql.py --check  # CI: fails if seed.sql is stale
```

## 3. Hosted project

1. **Create the project** in the Supabase dashboard (region: South Asia / Mumbai `ap-south-1` is
   closest to Sri Lanka). Note the project ref, the database password and the API keys.
2. **Link and push the schema**

   ```bash
   supabase login
   supabase link --project-ref <project-ref>
   supabase db push            # applies supabase/migrations in order
   ```

   The last migration (`20261006001300_function_privileges.sql`) self-checks the hardening
   rules (RLS on every table, `search_path=''` on every definer function, nothing executable
   by PUBLIC) and aborts the push if any rule is violated.
   Do **not** push `seed.sql` to production.
3. **Secrets for Edge Functions** (`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are injected
   automatically):

   ```bash
   supabase secrets set NIC_HMAC_KEY="base64:$(openssl rand -base64 48)" NIC_HMAC_KEY_VERSION=1
   supabase secrets set PAYHERE_MERCHANT_ID=<id> PAYHERE_MERCHANT_SECRET=<secret> PAYHERE_MODE=sandbox
   supabase secrets set ANTHROPIC_API_KEY=<key> AI_MODEL=claude-opus-5-5
   supabase secrets set APNS_KEY_ID=<kid> APNS_TEAM_ID=<team> APNS_TOPIC=<bundle id> APNS_ENV=production
   supabase secrets set APNS_KEY_P8="$(cat AuthKey_<kid>.p8)"
   supabase secrets list
   ```

   Keep `NIC_HMAC_KEY` in a password manager: rotating it changes every digest (see
   `SECURITY_BACKEND.md` §5). Optional: `PAYHERE_RETURN_URL`, `PAYHERE_NOTIFY_URL`,
   `PAYHERE_FALLBACK_EMAIL`, `AI_EFFORT`, `AI_FALLBACKS` (see `supabase/functions/.env.example`).
4. **Deploy functions**

   ```bash
   supabase functions deploy nic-digest payhere-checkout payhere-notify payhere-return \
     ai-organizer-copilot delete-account organizer-export push-dispatch
   ```

   `config.toml` sets `verify_jwt = false` only for `payhere-notify` (PayHere server callback,
   authenticated by `md5sig`), `payhere-return` (browser redirect) and `push-dispatch`
   (checks the service-role key itself). All user-facing functions keep `verify_jwt = true`
   and additionally validate the token with `auth.getUser`.
5. **Storage seed (staging only)**: `SUPABASE_URL=https://<ref>.supabase.co SUPABASE_SERVICE_ROLE_KEY=<key> ./scripts/seed-storage.sh`.
   The buckets `event-media` (public, 8 MB) and `avatars` (private, 3 MB), both limited to
   JPEG/PNG/HEIC/WebP, are created by migration `20261006001200`.

## 4. Auth

* **Redirect allow list** (Dashboard → Authentication → URL Configuration): Site URL
  `zuno://auth/callback`; additional redirect URLs `zuno://auth/callback` and
  `zuno://payments/return`. These match `config.toml`.
* **E-mail confirmations** are on. Configure a custom SMTP sender before launch (the built-in
  sender is rate limited to a few mails per hour).
* **Apple**: enable the provider; client IDs = the iOS bundle id (native Sign in with Apple)
  and, if web sign-in is needed, the Services ID; secret = the generated client-secret JWT
  (rotate before it expires, max 6 months).
* **Google**: enable; client IDs = iOS client id (and web client id); secret = web client
  secret.
* The `zuno_on_auth_user_created` trigger creates `profiles`, `wallets` and
  `notification_preferences` rows for every new user; `zuno_on_auth_identity_*` keep
  `user_identities` in sync; `zuno_on_auth_user_deleting` anonymises financial records when a
  user is deleted by any path (Admin API, dashboard or SQL).

## 5. pg_cron (order and offer expiry)

`public.expire_stale_orders()` releases ticket reservations of unpaid orders after
`order_hold_minutes` (15), fails their pending wallet top-ups, releases expired waitlist offers
and prunes old rate-limit windows. Expired holds are also released lazily when someone checks
out the same event, so the system is correct without cron, but inventory frees up faster with it.

1. Dashboard → Database → Extensions → enable **pg_cron**.
2. Run once in the SQL editor (the same block is in migration `20261006001200`, which schedules
   automatically when pg_cron is already enabled at push time):

   ```sql
   select cron.schedule('zuno-expire-stale-orders', '* * * * *', 'select public.expire_stale_orders()');
   ```
3. Check: `select * from cron.job_run_details order by start_time desc limit 5;`

## 6. Realtime

Migration `20261006001200` adds `notifications`, `orders` and `wallet_ledger` to the
`supabase_realtime` publication. RLS applies to `postgres_changes`, so a client subscribed to
`notifications` only receives its own rows. Nothing else needs to be enabled.

## 7. Push notifications

`push-dispatch` is service-role only. Two ways to trigger it:

* **Database Webhook** (recommended): Dashboard → Database → Webhooks → new webhook on
  `public.notifications`, event `INSERT`, type *Supabase Edge Function* `push-dispatch`,
  HTTP header `Authorization: Bearer <service_role key>`. The function accepts the webhook
  payload directly and respects each user's `notification_preferences`.
* From a trusted server: `POST /functions/v1/push-dispatch` with
  `{ "user_ids": [...], "title": "...", "body": "...", "data": {...} }`.

## 8. Rate limits

| Where | Limit |
|---|---|
| `nic-digest` | 5 / hour / user |
| `payhere-checkout` | 20 / 10 min / user |
| `ai-organizer-copilot` | 10 / hour / user (idempotent replays of a finished `request_id` are free) |
| `delete-account` | 3 / hour / user |
| `organizer-export` | 20 / hour / user |
| `check_in_ticket` RPC | 120 / minute / organizer |
| `send_event_update` RPC | 10 / hour / event |
| Supabase Auth | `config.toml` `[auth.rate_limit]` (mirror them in the dashboard for hosted projects) |

Counters live in `public.rate_limits` (fixed windows) and are pruned by `expire_stale_orders()`.
Consider also enabling the Supabase network restrictions / WAF rate limiting for the Data API.

## 9. Verification

```bash
PG_BIN=/path/to/postgres/bin ./scripts/db-verify.sh   # vanilla PostgreSQL 17 + Supabase stubs
./scripts/functions-check.sh                         # deno check + deno test
```

See `VERIFICATION.md` for what these cover and what still needs a hosted project.
