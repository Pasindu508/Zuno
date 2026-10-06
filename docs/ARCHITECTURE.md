# Zuno iOS — Architecture

## Stack

| Concern | Choice |
|---|---|
| Language / UI | Swift 6 (strict concurrency), SwiftUI, iOS 26+ (built with Xcode 27 / iOS 27 SDK) |
| State | Apple Observation (`@Observable`), structured concurrency (`async`/`await`, actors) |
| Project | XcodeGen (`project.yml` → `Zuno.xcodeproj`), Swift Package Manager |
| Backend | Supabase (Auth, PostgREST, RPC, Storage, Realtime, Edge Functions) via `supabase-swift` 2.55 |
| System frameworks | AuthenticationServices, LocalAuthentication, AVFoundation, MapKit, CoreLocation, EventKit/EventKitUI, UserNotifications, PhotosUI, WebKit, CoreImage |
| Tests | XCTest (unit, 68 tests) and XCUITest (17 flow tests + screenshot tour) |

## Layers

```
Zuno/
  App/                  composition root: ZunoApp, AppEnvironment (DI), MainTabView + AppRouter, configuration
  Core/
    DesignSystem/       palette, typography (Sansita One + SF), metrics, Liquid Glass modifiers, components
    Networking/         Supabase client factory + error mapping, image pipeline, connectivity
    Security/           Keychain, Apple nonce, biometric gate
    Storage/            protected file store, offline ticket cache, non-sensitive preferences
    Authentication/     AuthService protocol, Supabase implementation, provider seams, SessionStore (router)
    Utilities/          LKR / Asia-Colombo formatting, Sri Lankan districts and cities
  Domain/
    Models/             value types + pure policies (allowance, commission, pricing, search, filters,
                        calendar grouping, check-in state machine, primary-action resolution)
    Repositories/       protocols; Live/ (Supabase) and Development/ (DEBUG-only in-memory backend)
  Features/             one folder per feature: views + feature models (@Observable, MainActor)
```

**Rules followed**

* Views are declarative; side effects live in feature models and repositories.
* Features depend on repository **protocols** (`EventRepository`, `RegistrationRepository`,
  `CheckoutRepository`, `WalletRepository`, `TicketRepository`, `ProfileRepository`,
  `NotificationRepository`, `OrganizerRepository`, `CheckInRepository`, `AuthService`).
  `AppEnvironment` injects either the Supabase implementations or the development backend.
* Business rules that the server enforces are mirrored as **pure Swift policies**
  (`FreeRegistrationPolicy`, `CommissionPolicy`, `OrderPricing`, `EventFilters`,
  `CheckInStateMachine`, `EventPrimaryAction`) only to explain outcomes before the user
  confirms and to drive the development backend. The database is authoritative.

## Runtime configurations

| Build configuration | Backend | Notes |
|---|---|---|
| Development (Debug) | Supabase if `Config/Secrets.Development.xcconfig` provides host + key, otherwise the development backend | `-zuno-dev-backend` forces the development backend |
| Test (Debug) | Development backend (UI tests pass `-zuno-dev-backend`) | Deterministic provider stubs via `-zuno-stub-providers` |
| Production (Release) | Supabase only | Development backend, stubs and fixtures are compiled out (`#if DEBUG`, `EXCLUDED_SOURCE_FILE_NAMES`). Missing configuration shows a configuration error screen — never fake data. |

### The development backend (test seam)

`Domain/Repositories/Development/DevelopmentBackend.swift` is an actor that implements every
repository protocol from `supabase/seed/zuno_seed.json` — the same file `supabase/seed.sql` is
generated from. It applies the server rules (allowance, wallet deduction with fee confirmation,
capacity, waitlist offers, idempotent replays, inventory reservation, payment notification
idempotency, check-in transitions) so the simulator and UI tests behave like production.
It exists only in Debug builds. Payments in this mode use a clearly labelled **development
payment simulator** that drives the same "wait for server-verified order status" path.

## Navigation

* `RootRouterView` switches on `SessionStore.route`:
  `launching → onboarding → auth → profileSetup → identitySetup → main` (plus `configurationError`).
* `MainTabView` is a native `TabView` with four `Tab`s (Home, Calendar, Tickets, Profile).
  Each tab owns a `NavigationStack` bound to `AppRouter` paths, so stacks survive tab switches.
* `AppRoute` + `AppDestination` resolve every destination in one place.
* Event cards use `matchedTransitionSource` + `.navigationTransition(.zoom)` for the
  card → detail transition.
* Guests can browse; registering, saving and checkout call `SessionStore.requireAccount(for:)`,
  which presents sign-in and resumes the **pending intent** (e.g. opens the registration sheet)
  after authentication.

## Authentication

* `SessionStore` is the single observer of `AuthService.authEvents()`; it restores the session
  (Supabase stores it in the Keychain), refreshes an expired stored session once, loads or
  creates the profile and routes.
* Apple: `ASAuthorizationAppleIDButton` → `SystemAppleAuthorizer` (secure nonce, SHA-256 to
  Apple) → `signInWithIdToken` with the raw nonce. Name is saved on first authorization.
  Credential revocation is checked at launch.
* Google: `signInWithOAuth(provider: .google, scopes: "openid email profile")` with PKCE through
  `ASWebAuthenticationSession`; callbacks are validated (`OAuthCallback`) before the code exchange.
* Linking/unlinking: `linkIdentityWithIdToken` (Apple), `getLinkIdentityURL` + web session
  (Google), `update(user:)` (email). Fresh local authentication is always required first.

## Payments

`payhere-checkout` (Edge Function) creates the order from database prices, reserves inventory
and returns a signed PayHere form. `PayHereCheckoutView` posts it in a non-persistent web view
and closes on the return/cancel URL. The app then **polls the order** (and listens for the
`zuno://payments/return` deep link) until the server — after verifying PayHere's signed
`payhere-notify` callback — marks it paid, failed, cancelled or expired. Tickets and top-ups
exist only after that verification.

## Images

`ImagePipeline` (actor) de-duplicates requests, downsamples with ImageIO to the displayed size,
caches decoded images in a cost-limited `NSCache` (trimmed under memory pressure) and uses a
256 MB URL cache on disk. `ArtworkImage` cancels with its view, shows a shimmer placeholder, a
retry control and a category-symbol fallback. Feeds prefetch the next covers. Event media comes
from the public `event-media` bucket; avatars are downloaded with the user's session.

## Offline

* Issued tickets are cached per user in Application Support with
  `completeFileProtectionUnlessOpen`, excluded from backup, and cleared on sign-out.
* The scanner refuses to admit anyone without server validation (`offlineRestricted` state).
* `NetworkMonitor` drives offline banners.

## Liquid Glass usage

Native APIs only: `glassEffect(_:in:)` with tinted `Glass.regular`, `.interactive()` on
custom controls, `GlassEffectContainer` + `glassEffectID` for the search/filter morph and the
favorite/share pair, native `TabView` / toolbars / sheets, `scrollEdgeEffectStyle`. Event cards
and information panels stay solid charcoal (`#232321`) as in the reference. Under Reduce
Transparency the custom glass switches to `.identity` with a solid charcoal fill.
