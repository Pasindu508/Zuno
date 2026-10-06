# Sign in with Google — setup

Zuno signs in with Google through **Supabase's Google provider** using the OAuth 2.0
Authorization Code flow with **PKCE**, presented in `ASWebAuthenticationSession`. The Google
client secret lives only in Supabase — never in the app.

## How the app does it

1. `GoogleSignInButton` follows Google's branding (full-colour "G" mark, light button,
   `#1F1F1F` label, neutral outline). The label uses SF Pro rather than Roboto; review against
   Google's current guidelines before release.
2. `SupabaseAuthService.signInWithGoogle` calls
   `auth.signInWithOAuth(provider: .google, redirectTo: zuno://auth/callback, scopes: "openid email profile")`
   with a custom launch flow:
   * `SystemWebAuthenticationRunner` opens the authorize URL in `ASWebAuthenticationSession`
     (callback scheme `zuno`).
   * `OAuthCallback.validate` checks scheme/host/path and maps `error=access_denied` →
     *consent denied*, `flow_state_*`/expired → *flow expired*, missing `code` → *missing
     session*, other hosts → *callback mismatch*.
   * The SDK exchanges `code` + `code_verifier` at `/token?grant_type=pkce`.
3. Linking Google to an existing account uses `getLinkIdentityURL` + the same web session.

Handled outcomes: success, cancellation (silent), consent denied, callback mismatch, expired
flow, missing session, network errors. Unit tests assert the authorize URL (`provider=google`,
`scopes=openid email profile`, `redirect_to`, `code_challenge_method=s256`) and the PKCE
exchange body against a mocked Supabase, plus every callback error mapping.

## Google Cloud (credential-dependent)

1. Create an OAuth consent screen (External), scopes `openid`, `email`, `profile` only.
2. Create a **Web application** OAuth client. Authorized redirect URI:
   `https://<project-ref>.supabase.co/auth/v1/callback`.
3. (Optional) Create an iOS client for future native Google Sign-In; put its id in
   `ZUNO_GOOGLE_IOS_CLIENT_ID`. It is not required for the Supabase OAuth flow.

## Supabase

* Authentication → Providers → **Google**: client id + client secret of the Web client.
* Authentication → URL Configuration: add `zuno://auth/callback` to the redirect allow list
  (already in `supabase/config.toml`).
* The URL type `zuno` is registered in `Info.plist` via `project.yml`.

## Account merging

Zuno never merges accounts because email strings match: all data is keyed by the Supabase user
id. Note that Supabase itself links identities automatically when **both** emails are verified
by trusted providers; this is documented in `SECURITY.md`.
