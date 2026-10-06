# Zuno

Zuno is a Sri Lankan app for discovering community meetups, hackathons, university workshops,
technology events, cultural gatherings, exhibitions and paid experiences — and for registering,
paying and checking in.

This repository contains the **native iOS app** (Swift 6, SwiftUI, iOS 26+) and its **Supabase
backend** (PostgreSQL schema with Row Level Security, transactional RPCs, Storage, Realtime and
Deno Edge Functions). The backend contract (`docs/BACKEND_CONTRACT.md`) is shared with the
future web and Android clients.

The visual design follows the dark museum-style references: near-black `#111110` background,
charcoal `#232321` surfaces, amber `#EDA71A` accents, white `#FFFFFF` text and selected states,
**Sansita One** event titles, SF Pro everywhere else, SF Symbols, and native Liquid Glass on the
floating controls.

## Quick start (simulator, no credentials needed)

Requirements: macOS with **Xcode 27** (iOS 26+ SDK), an iOS simulator, network access for the
first package resolution.

```bash
scripts/bootstrap.sh          # downloads XcodeGen 2.46.0 into .tools/
scripts/generate.sh           # Zuno.xcodeproj from project.yml
scripts/run-simulator.sh -- -zuno-dev-backend -zuno-signed-in
```

Without Supabase configuration a **Debug** build runs against the built-in development backend
(seed data from `supabase/seed/zuno_seed.json`, fictional organizers and events, original
procedurally generated artwork). Useful launch arguments (Debug only):

| Argument | Effect |
|---|---|
| `-zuno-dev-backend` | use the development backend even if Supabase is configured |
| `-zuno-signed-in` | start signed in as the development user (Nethmi Perera) |
| `-zuno-reset` | clear local state first |
| `-zuno-skip-onboarding` | start at sign-in |
| `-zuno-stub-providers` | deterministic Apple/Google/biometric/camera stubs (UI tests) |
| `-zuno-organizer` | the development user owns a verified organizer with attendees |
| `-zuno-biometric success\|failure` | force the App Lock outcome |
| `-zuno-scanner-code ZN-TEST-0001` | the stub scanner "detects" this code |
| `-zuno-light` | light appearance |

Open `Zuno.xcodeproj` in Xcode to run normally; the *Zuno* scheme runs **Development**, tests
run **Test**, archive uses **Production**.

## Connecting a real backend

1. Set up Supabase: `docs/backend/SUPABASE_SETUP.md` (migrations, functions, secrets, storage,
   auth providers, pg_cron, webhooks).
2. `cp Config/Secrets.example.xcconfig Config/Secrets.Development.xcconfig` and fill in
   `ZUNO_SUPABASE_HOST`, `ZUNO_SUPABASE_PUBLISHABLE_KEY`, `ZUNO_DEVELOPMENT_TEAM`
   (git-ignored; only publishable values belong in the app).
3. Providers and payments: `docs/APPLE_AUTH.md`, `docs/GOOGLE_AUTH.md`,
   `docs/backend/PAYHERE_SETUP.md`. Push: `docs/backend/SUPABASE_SETUP.md` §7.
4. `scripts/generate.sh` and build.

Configurations: **Development** (`lk.zuno.app.dev`), **Test** (`lk.zuno.app.test`),
**Production** (`lk.zuno.app`, PayHere live, APNs production; development backend and fixtures
compiled out).

## Tests

```bash
scripts/test.sh                       # 68 unit tests (XCTest)
scripts/test.sh --ui                  # + 17 UI flow tests (XCUITest)
scripts/screenshots.sh                # screenshot tour on iPhone 17e / 17 / 18 Pro Max
PG_BIN=/path/to/pg/bin scripts/db-verify.sh   # 13 migrations + seed + 594 SQL assertions on PostgreSQL 17
DENO=/path/to/deno scripts/functions-check.sh # deno check + 64 Edge Function tests
```

## Repository layout

```
project.yml                 XcodeGen spec (targets, configs, Info.plist, entitlements, SPM)
Config/                     xcconfigs (Base, Development, Test, Production, Secrets.example)
Zuno/                       app sources — App, Core, Domain, Features, Resources
ZunoTests/  ZunoUITests/    unit and UI tests
supabase/                   config.toml, migrations, seed, functions, SQL tests
scripts/                    bootstrap, generate, run, test, screenshots, artwork, db/functions checks
docs/                       architecture, contract, setup guides, security, privacy, checklists, status
ThirdParty/Licenses/        Sansita One — SIL Open Font License 1.1
artifacts/screenshots/      simulator screenshots used for visual review
```

## Documentation

| Document | Contents |
|---|---|
| `docs/FEATURE_STATUS.md` | what is verified, seed-backed, credential- or device-dependent, incomplete |
| `docs/ARCHITECTURE.md` | layers, DI, navigation, auth, payments, images, offline, glass |
| `docs/BACKEND_CONTRACT.md` | tables, views, RPCs, Edge Functions, storage, error codes |
| `docs/backend/SUPABASE_SETUP.md` | backend setup end to end |
| `docs/backend/PAYHERE_SETUP.md` | PayHere merchant, sandbox, notify URL, hashes |
| `docs/backend/SECURITY_BACKEND.md` / `docs/SECURITY.md` | RLS matrix, secrets, client boundary, assumptions |
| `docs/backend/VERIFICATION.md` | exactly what the backend checks ran and their results |
| `docs/APPLE_AUTH.md`, `docs/GOOGLE_AUTH.md` | provider setup |
| `docs/PRIVACY.md` | data, permissions, NIC handling, deletion |
| `docs/ACCESSIBILITY_CHECKLIST.md` | VoiceOver, Dynamic Type, contrast, motion, transparency |
| `docs/DEVICE_TESTING_CHECKLIST.md` | items that need hardware or live credentials |
| `docs/LOCALIZATION.md` | English, Sinhala, Tamil readiness and formats |
| `docs/VISUAL_QA.md` | screenshot comparison against the references |
| `docs/IMPLEMENTATION_CHECKLIST.md` | reference measurements and the build checklist |

## Credits and licences

* **Sansita One** © Omnibus-Type, SIL Open Font License 1.1 — `ThirdParty/Licenses/SansitaOne-OFL.txt`
  (bundled in the app as well).
* Event artwork, onboarding images, app icon and launch wordmark are original, generated
  procedurally by `scripts/generate-artwork.swift`. The reference images' paintings, names and
  texts are not used.
* Google "G" logo used only on the Google sign-in button, per Google's sign-in branding
  guidelines.
* All organizers, people and events in the seed data are fictional samples.
