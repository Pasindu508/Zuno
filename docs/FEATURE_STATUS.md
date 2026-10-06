# Zuno — Feature status

Status as of 2026-10-06. Categories:

* **Verified locally** — built and exercised here: unit/UI tests and simulator review against the
  development backend, and/or the SQL functions on PostgreSQL 17 with Supabase stubs.
* **Development seed data** — works in the simulator using the DEBUG development backend and the
  shared fictional seed; the live implementation exists but hasn't run against a hosted project.
* **Credential-dependent** — needs real Supabase / Apple / Google / PayHere / Anthropic / APNs
  credentials to verify end to end.
* **Physical-device dependent** — needs hardware (Face ID, camera, haptics, push, real glass rendering).
* **Incomplete** — not built, or built only partially.
* **Unverified** — implemented but not exercised at all.

Test totals: **73 unit tests pass** (XCTest), **17 UI flow tests** (XCUITest, iPhone 17 simulator —
see the last run in the table below), **594 SQL assertions** in 12 suites, **64 Deno tests**,
`deno check` on 27 modules. Contract fixtures exported from the real SQL functions decode with the
app's DTOs (`ContractFixtureTests`).

| Area | Feature | Status | Evidence / notes |
|---|---|---|---|
| Project | XcodeGen `project.yml` → `Zuno.xcodeproj`, 3 configurations | Verified locally | `scripts/generate.sh`; Development/Test builds; Production compiles out DEBUG code |
| Design | Palette `#111110 / #232321 / #EDA71A / #FFFFFF`, Sansita One + SF Pro + SF Mono | Verified locally | `ZunoColor`, `ZunoTypography`; screenshots in `artifacts/screenshots` |
| Design | Native Liquid Glass (controls, tab bar, sheets, search morph) | Verified locally (simulator) · Physical-device dependent | Simulator rendering isn't proof of glass appearance |
| Design | Light appearance, Reduce Transparency/Motion, Increase Contrast, Dynamic Type fallback | Verified locally | screenshots (light, large text); `ACCESSIBILITY_CHECKLIST.md` |
| Launch | Branded launch screen, splash, onboarding (3 pages) | Verified locally | UI test 01 |
| Auth | Sign in with Apple (nonce, id-token exchange, name capture, revocation check) | Verified locally (unit, mocked Supabase) · Credential- & device-dependent | `AppleSignInTests`; UI test 02 uses a stub (test state) |
| Auth | Google OAuth PKCE via ASWebAuthenticationSession, callback validation | Verified locally (unit, mocked Supabase) · Credential-dependent | `GoogleOAuthTests`; UI test 03 test state |
| Auth | Email sign-in, sign-up + verification, password reset, recovery sheet | Development seed data · Credential-dependent | UI test 04 (dev auth) |
| Auth | Session restoration, refresh, expiry notice, sign-out cleanup | Verified locally (routing) · Credential-dependent (token refresh) | `SessionRoutingTests` |
| Auth | Linked identities: link Apple/Google/email, unlink with ≥1 remaining, fresh local auth | Development seed data · Credential-dependent | `IdentityLinkingTests` |
| Auth | Account deletion (Edge Function + local cleanup) | Development seed data · Credential-dependent | function unit-tested in Deno |
| Profile | Profile setup (name, photo, city, interests, language, accessibility) | Verified locally | UI test 02 |
| Identity | NIC duplicate prevention (HMAC digest server-side, never stored) | Verified locally (SQL + Deno + dev backend) · Credential-dependent (HMAC key) | `BackendRulesTests`, Deno `nic_test`, SQL suite 090 |
| Home | Location header, search, category capsules, vertical sectioned feed, skeletons, offline banner | Verified locally | UI tests 05–07; screenshots |
| Search & filters | Text search (name, organizer, category, venue, city, university, date words), filter sheet with live count | Verified locally | `SearchTests`, `FilterTests`, UI tests 07–08; SQL suite 100 |
| Details | Artwork header with glass back/favorite/share/date pill, map, tiers, agenda, speakers, questions, refunds, related, CTA states | Verified locally | UI tests 09–10; `PrimaryActionTests` |
| Calendar | Month grid, agenda, registered/saved, Add to Calendar (system editor) | Verified locally | `CalendarGroupingTests`; screenshots |
| Registration | 15 free/month, exact LKR fee from wallet after allowance, capacity, duplicate, idempotency, required answers, waitlist offers | Verified locally (SQL authoritative + dev backend + UI) | SQL suites 020/030/110; `BackendRulesTests`; UI test 11 |
| Checkout | Tiers/quantities, order summary, PayHere checkout, pending/success/failed/cancelled/expired, receipts | Verified locally (dev simulator + SQL + Deno) · Credential-dependent (PayHere) | UI test 12; SQL suite 040; Deno payhere tests |
| Payments | Signature verification, duplicate callbacks, server-priced orders, inventory holds | Verified locally (SQL + Deno) · Credential-dependent | SQL 040/110, Deno `payhere_test` |
| Wallet | Balance, allowance meter, top-up, append-only ledger, transaction details, low balance | Verified locally · Credential-dependent (PayHere top-up) | UI test 14; SQL suite 070 |
| Tickets | Upcoming/past/cancelled, detail, white QR, full-screen QR with brightness, offline cache | Verified locally | UI test 13; `TicketGroupingTests` |
| Organizer | Organizer profile, dashboard, sales/settlements (gated), event editor, venues, tiers, questions, preview | Verified locally (dev) · Credential-dependent | UI test 17; SQL suite 060 |
| Organizer | Event creation fee + publish validation | Verified locally (dev + SQL) · Credential-dependent | `BackendRulesTests.testOrganizerPublishValidation`; SQL 060 |
| Organizer | Send updates, CSV export | Development seed data (+ SQL/Deno) · Credential-dependent | SQL 060, Deno `csv_test` |
| AI copilot | Agenda/questions via Edge Function (Anthropic SDK, structured output, refusal/timeout/malformed handling, approval) | Verified locally (Deno with injected transport; dev failure paths) · Credential-dependent (Anthropic key) | Deno `ai_test`, `handler_test`; UI test 17 |
| Check-in | AVFoundation scanner, manual fallback, server validation, all result states, duplicate-scan guard, offline restriction | Verified locally (state machine, dev backend, SQL, stub scanner UI) · Physical-device dependent (camera) | `CheckInStateMachineTests`; UI test 16; SQL suites 050/110 |
| Notifications | In-app center, unread, mark read, Realtime refresh, settings with opt-in explanation | Development seed data · Credential-dependent (Realtime) | screenshots |
| Push | APNs token registration, `push-dispatch` (ES256 JWT) | Credential- & physical-device dependent | Deno `apns_test` |
| Biometrics | App Lock (Face ID/Touch ID/passcode), gated wallet/tickets/financials/scanning, always-on for identity changes | Verified locally (stubbed) · Physical-device dependent | `IdentityLinkingTests`; UI test 15 |
| Haptics | Semantic `sensoryFeedback` | Physical-device dependent | simulator has no Taptic Engine |
| Images | Downsampling pipeline, cache, cancellation, retry, fallback, prefetch | Verified locally (bundled fixtures) · Credential-dependent (Storage) | screenshots |
| Localization | English complete; Sinhala/Tamil declared, string catalog, LKR/Colombo formats, inflection | Incomplete (translations) | `LOCALIZATION.md`, `FormattingTests` |
| iPad | Adaptive grid, two-column detail, Split View sizes | Verified locally (simulator screenshots) | `VISUAL_QA.md` |
| Apple Wallet passes | — | Incomplete (intentionally not built: no pass-signing backend) | per spec |
| Backend | Migrations, RLS on every table, grants, definer hardening, storage policies, realtime, cron | Verified locally (PostgreSQL 17 + stubs) · Unverified on hosted Supabase | `docs/backend/VERIFICATION.md` |
