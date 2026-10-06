# Zuno — Security notes (iOS client)

Backend details (RLS matrix, definer-function hardening, secrets, logging): see
`docs/backend/SECURITY_BACKEND.md`. This page covers the app and the client/server boundary.

## Server-authoritative by design

| Concern | Where it is decided | What the app sends |
|---|---|---|
| Monthly free allowance, wallet fee | `register_for_free_event` (row locks, Asia/Colombo month) | event id, answers, the fee the user saw (`p_expected_fee_minor`), idempotency key |
| Capacity, duplicates, waitlist offers | same RPC / `join_waitlist` / `cancel_registration` | ids only |
| Ticket prices, totals, commission | `create_payment_order` (called by `payhere-checkout`) | tier ids + quantities |
| Payment success | `payhere-notify` verifies `md5sig`, amount and currency, idempotently | nothing — the return URL is never trusted |
| Ticket issuance | only after verified payment / confirmed free registration | — |
| Check-in | `check_in_ticket` atomic `valid → checked_in` | event id + scanned code |
| NIC duplicate check | `nic-digest` HMAC-SHA-256 with a server key | the NIC once over TLS |
| Identity / organizer verification status | server-owned columns | — |
| AI copilot | `ai-organizer-copilot` (no auth, money, capacity or QR decisions) | event id, kind, optional notes |

## Secrets

* The app contains only the **Supabase URL and publishable key** (from git-ignored
  `Config/Secrets.*.xcconfig`). No service-role key, PayHere merchant secret, Apple private key,
  Google client secret, AI key, APNs key or NIC HMAC key is ever in the app or the repository.
* `.gitignore` excludes `Config/Secrets.*.xcconfig`, `supabase/.env`, `*.p8`, `*.p12`.
* Only `*.example` configuration files are committed.

## On the device

* **Sessions**: stored by supabase-swift's `KeychainLocalStorage`; tokens never touch
  `UserDefaults`. Auto-refresh is on; an expired stored session gets one refresh attempt, then
  the user is signed out with a notice.
* **Keychain** (`WhenUnlockedThisDeviceOnly`): App Lock preference, Apple user identifier.
* **Offline tickets**: Application Support, `completeFileProtectionUnlessOpen`, excluded from
  backup, removed on sign-out and account deletion.
* **UserDefaults**: only non-sensitive conveniences (onboarding flag, appearance, selected city,
  recent searches).
* **Sign-out** clears the ticket cache, decoded image cache, biometric unlocks, per-user
  preferences and Keychain values.
* **NIC**: typed into a secure field, normalised (uppercase, separators removed) and sent once;
  the field is cleared immediately after submission. The app never hashes, stores or logs it.
* **PayHere** pages load in a non-persistent `WKWebView` data store.
* **Biometrics** (`LAContext`, `.deviceOwnerAuthentication` with passcode fallback) supplement
  the Supabase session: they gate wallet, ticket details, organizer financials, scanning and —
  always, with no grace period — identity linking/unlinking and account deletion.

## Account linking

Accounts are never merged because email strings match; every row is keyed by the Supabase user
id. **Assumption**: Supabase Auth automatically links a new OAuth identity to an existing user
when both emails are verified by trusted providers. If that is unacceptable for a deployment,
require users to link manually from *Profile › Sign-in methods* and review Supabase's identity
linking settings.

## Remaining assumptions / open items

* Hosted Supabase behaviour (storage policies, auth triggers, realtime, cron) was verified on
  vanilla PostgreSQL with stubs, not on a hosted project.
* PayHere, Apple, Google, Anthropic and APNs were not exercised against live services.
* Certificate pinning is not implemented (standard ATS/TLS only).
* Jailbreak detection is out of scope.
* Signed-in users can read verified organizers' `contact_email` and the `online_url` column of
  published events directly from the table (see backend VERIFICATION.md §3.9).
