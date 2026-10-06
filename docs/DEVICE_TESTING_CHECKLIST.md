# Zuno — Device testing checklist

The simulator verifies layout, flows and logic. These items need a **signed build on physical
hardware** and/or **live credentials**. Tick them before a TestFlight release.

## Prerequisites

- [ ] Apple Developer team set in `Config/Secrets.Development.xcconfig` (`ZUNO_DEVELOPMENT_TEAM`)
- [ ] App IDs with Sign in with Apple + Push Notifications for the bundle ids
- [ ] Supabase project linked, migrations pushed, functions deployed, secrets set
      (`docs/backend/SUPABASE_SETUP.md`)
- [ ] `ZUNO_SUPABASE_HOST` / `ZUNO_SUPABASE_PUBLISHABLE_KEY` configured
- [ ] PayHere sandbox merchant configured (`docs/backend/PAYHERE_SETUP.md`)
- [ ] Google OAuth web client configured in Supabase (`GOOGLE_AUTH.md`)

## Authentication

- [ ] Sign in with Apple — first sign-in shares name; profile setup pre-filled
- [ ] Sign in with Apple — "Hide My Email" relay address accepted
- [ ] Revoke Zuno in *Settings › Apple Account › Sign in with Apple* → next launch signs out with a notice
- [ ] Google — consent, cancel, deny consent; each shows the right state (cancel shows nothing)
- [ ] Email — sign up, confirmation link opens the app (`zuno://auth/callback`), sign in, wrong password
- [ ] Password reset link opens the app and the new-password sheet
- [ ] Session restore after force-quit; after 1 h+ background (token refresh)
- [ ] Link Apple / Google / email; unlink keeps at least one method; both ask for Face ID first
- [ ] Delete account → user removed in Supabase, local data cleared

## Biometrics & security

- [ ] Face ID prompt for App Lock enable, wallet, ticket details, organizer financials, scanning
- [ ] Face ID failure → passcode fallback; lockout message after repeated failures
- [ ] Device without Face ID enrolled → optional gates pass, identity changes ask for a passcode
- [ ] Background → foreground clears unlocks

## Payments (PayHere sandbox)

- [ ] Ticket purchase success → tickets appear only after `payhere-notify` arrives
- [ ] Card declined → "Payment failed", inventory released
- [ ] Cancel on PayHere page → "Payment cancelled"
- [ ] Leave the PayHere page for > 15 min → order expires, held tickets released
- [ ] Wallet top-up success / failure; ledger shows pending → completed / failed
- [ ] Event creation fee → publish

## Tickets & check-in

- [ ] Ticket QR scans with the organizer device's camera (bright screen, white surface)
- [ ] Airplane mode: tickets still open with QR; scanner shows "Check-in paused"
- [ ] Scan valid → one pulse + success haptic; scan again → "Already used"; other event → "Different event"
- [ ] Manual code entry works with and without dashes

## Notifications

- [ ] Opt in from Notification settings (explanation first), token stored in `push_devices`
- [ ] Database webhook → `push-dispatch` delivers registration / payment / venue-change pushes
- [ ] Foreground notifications show a banner; in-app center updates via Realtime

## Haptics (physical feedback only verifiable on device)

- [ ] Selection on categories / filters / segmented controls
- [ ] Light impact when search expands
- [ ] Success: registration, payment, favorite, valid check-in
- [ ] Warning: low wallet balance, low availability
- [ ] Error: invalid ticket, failed payment, validation failure

## Layout & accessibility on hardware

- [ ] iPhone 17e / 17 / 17 Pro Max / Air portrait and landscape
- [ ] iPad: regular width grid, two-column event detail, Split View 1/3 and 1/2, Stage Manager
- [ ] Dynamic Type AX5, VoiceOver, Voice Control, Switch Control, Increase Contrast,
      Reduce Motion, Reduce Transparency, Differentiate Without Color
- [ ] Liquid Glass at different *Settings › Display › Liquid Glass* intensities
      (simulator rendering is not proof of glass appearance)
- [ ] Sinhala and Tamil system languages: layout, fonts (Sansita One is Latin-only; Sinhala and
      Tamil titles fall back to the system font), right-to-left pseudo-language
