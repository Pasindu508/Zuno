# Sign in with Apple — setup

Zuno uses native Sign in with Apple (AuthenticationServices) and exchanges the Apple identity
token for a Supabase session with `signInWithIdToken`. No Apple private key is ever in the app.

## How the app does it

1. `AppleSignInButton` wraps Apple's official `ASAuthorizationAppleIDButton` (white style,
   documented corner radius only — no glass or overlays).
2. `SystemAppleAuthorizer` generates a 32-character nonce with `SecRandomCopyBytes`, sends
   `SHA256(nonce)` to Apple, and requests `.fullName` and `.email` **only when creating/signing
   in**. Linking and re-authentication request no scopes.
3. `SupabaseAuthService.signInWithApple` calls
   `auth.signInWithIdToken(OpenIDConnectCredentials(provider: .apple, idToken:, nonce: rawNonce))`.
4. Apple returns the user's name only on the first authorization; Zuno saves it to the user
   metadata (`full_name`) and pre-fills profile setup. If it's missing, profile setup asks.
5. The Apple user identifier is kept in the Keychain; at launch `SessionStore` calls
   `getCredentialState(forUserID:)` and signs out locally on `.revoked` / `.notFound`.

Handled outcomes: success, cancellation (silent), missing identity token, revoked credential,
provider failure, network error. Unit tests cover the nonce, the SHA-256 vector and the exact
`grant_type=id_token` request body (raw nonce, not the hash) against a mocked Supabase.

## Apple Developer account (credential-dependent)

1. **Identifiers → App IDs**: for each bundle id (`lk.zuno.app`, `lk.zuno.app.dev`,
   `lk.zuno.app.test`) enable **Sign in with Apple** (and Push Notifications).
2. The capability is already declared in `Zuno/Resources/Zuno.entitlements`
   (`com.apple.developer.applesignin = [Default]`, generated from `project.yml`).
3. Set your team in `Config/Secrets.<Environment>.xcconfig` (`ZUNO_DEVELOPMENT_TEAM`) and let
   Xcode manage signing.
4. **Keys**: create a *Sign in with Apple* key (only needed for the Supabase client secret and
   server-to-server notifications — keep the `.p8` out of the repository).

## Supabase

Dashboard → Authentication → Providers → **Apple**:

* **Client IDs**: the bundle ids above, comma separated (native sign-in validates the token's
  audience against these).
* **Secret key**: only required if you also offer web sign-in (Services ID + generated JWT,
  rotate every ≤ 6 months).
* Enable **Manual linking** (Authentication → Settings) so `linkIdentityWithIdToken` works.

## Verifying on a device

Sign in with Apple needs a signed build on a device (or a simulator signed in to an Apple
Account with a provisioned team). See `DEVICE_TESTING_CHECKLIST.md`. UI tests use a
deterministic stub (`-zuno-stub-providers`) and are labelled as a test state.
