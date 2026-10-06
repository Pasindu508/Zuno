# Zuno iOS — Implementation Checklist

Starting point (2026-10-06): the repository was empty. No previous Swift code, XcodeGen
configuration, Supabase schema, functions, environment files or design assets existed,
so everything is created fresh. Toolchain: Xcode 27.0 (Swift 6.4), iOS 27 simulators,
XcodeGen 2.46.0 (downloaded by `scripts/bootstrap.sh`).

Reference analysis (2000×1500 renders, iPhone frame ≈ 1.38 px/pt):

| Element | Measured | Implemented token |
|---|---|---|
| Side margin | 18 pt | `ZunoMetrics.margin = 18` |
| Search field / filter / bell / chip height | 49–50 pt | `controlHeight = 50` |
| Search → filter gap, chip gap | 9–10 pt | `10` |
| Event card | 357 × ~334 pt, artwork 211 pt, radius ≈ 16 pt | `cardRadius = 18`, artwork aspect 1.69 |
| Card title | Sansita One ≈ 24 pt | `ZunoFont.display(24, relativeTo: .title2)` |
| Detail artwork | inset 7–8 pt, top radius ≈ 28 pt, ≈ 57 % of height | `detailArtworkInset = 8`, radius 30 |
| Detail floating controls | 48–50 pt glass circles/pill straddling the artwork's bottom edge | `FloatingGlassIconButton`, `DatePill` |
| Detail title | Sansita One ≈ 30 pt, 2 lines | `display(30, relativeTo: .largeTitle)` |
| Primary button | 361 × 58 pt white capsule | `PrimaryCapsuleButtonStyle` |
| Palette | `#111110`, `#232321`, `#EDA71A`, `#FFFFFF` | `ZunoColor` |

## Checklist

- [x] Inspect repository and references; record measurements
- [x] Backend contract shared by iOS / future web / Android (`docs/BACKEND_CONTRACT.md`)
- [x] XcodeGen `project.yml`, xcconfigs (Development / Test / Production), example secrets
- [x] Sansita One (OFL) bundled, registered, licensed, with serif fallback
- [x] Design system tokens + reusable components (section 32)
- [x] Liquid Glass controls (back / favorite / share / date pill / bell / filter / sheets / tab bar)
- [x] Domain models, policies (allowance, commission, LKR), repositories with protocols
- [x] Live Supabase repositories (PostgREST, RPC, Functions, Storage, Realtime)
- [x] Development backend (DEBUG-only test seam) from shared seed JSON
- [x] Launch, onboarding, auth (Apple / Google / email), routing, identity linking
- [x] Profile setup + NIC digest flow
- [x] Home (header, search, chips, vertical feed), search, filters
- [x] Event details (artwork header, info, map, tiers, agenda, CTA)
- [x] Free registration (allowance + wallet fee), paid checkout (PayHere)
- [x] Wallet, tickets (QR, offline cache), calendar (month + agenda, EventKit)
- [x] Notifications center + settings, push preparation
- [x] Profile tab + settings (language, appearance, accessibility, biometrics, privacy, delete)
- [x] Organizer mode (profile, wizard, AI copilot, publish, stats, export, updates)
- [x] QR check-in (AVFoundation scanner + manual fallback)
- [x] Supabase migrations, RLS, storage policies, functions, seed (verified on local Postgres)
- [x] Unit tests + UI tests
- [x] Simulator screenshots across devices, visual comparison, fixes
- [x] Documentation + feature-status table

The final state of each item, with verification level, lives in `docs/FEATURE_STATUS.md`.
