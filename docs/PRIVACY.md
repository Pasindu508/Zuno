# Zuno — Privacy notes

## Data collected (linked to the user, not used for tracking)

| Data | Purpose | Where |
|---|---|---|
| Name, email, phone (optional) | account, receipts, ticket holder name | `profiles`, Supabase Auth |
| City / district, interests, language | recommendations, localisation | `profiles` |
| Accessibility needs (optional) | shared with organizers only when the user registers | `profiles`, registration answers |
| Registrations, tickets, orders, wallet ledger | core service, legal record keeping | respective tables |
| Answers to organizer questions | the organizer's event planning | `registration_answers` (owner + organizer only) |
| Profile photo (optional) | shown on tickets | private `avatars` bucket |
| NIC | **not stored** — only a keyed one-way digest for duplicate prevention | `identity_digests` (no client access) |
| Push token (optional) | notifications | `push_devices` |

The privacy manifest (`Zuno/Resources/PrivacyInfo.xcprivacy`) declares these types, no tracking,
and the UserDefaults required-reason API (`CA92.1`).

## Permissions — asked only when useful, after an explanation

| Permission | When | Explanation shown first |
|---|---|---|
| Location (when in use) | user taps *Use my current location* in the location picker | footer text in the picker + system prompt string |
| Camera | organizer taps *Allow camera* on the check-in screen | in-screen card |
| Notifications | user enables *Push notifications* in Notification settings | confirmation alert describing what will be sent |
| Face ID | user turns on App Lock (and identity changes) | settings row + `NSFaceIDUsageDescription` |
| Calendar | none — *Add to Calendar* uses the out-of-process system editor | — |
| Photos | none — `PhotosPicker` runs out of process | — |

Nothing is requested at launch or during onboarding.

## NIC handling

* Explained before entry (why, how it's protected, that a match does not verify ownership).
* Sent once to `nic-digest`, canonicalised server-side (old 9+V/X format → 12-digit), HMAC'd
  with a server-held key, stored as a digest only; never logged.
* Deleted with the account.

## Deletion

*Profile › Delete account* (requires typing DELETE and fresh device authentication) calls the
`delete-account` Edge Function: profile, saved items, notifications, push tokens, identities,
NIC digest and storage objects are removed; legally required financial records are anonymised;
then the auth user is deleted with the Admin API. The device's local data is cleared.

## Third parties

* **PayHere** processes card payments; Zuno never receives card data.
* **Anthropic** (AI copilot) receives event details an organizer is drafting — never attendee
  data, NICs or payments.
* **Apple / Google** for sign-in, with scopes limited to name and email (`openid email profile`).
