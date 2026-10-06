# Zuno — Accessibility checklist

Legend: ✅ implemented and checked in the simulator · 🧪 covered by automated tests ·
📱 needs a physical-device / assistive-technology pass before release.

## VoiceOver

- ✅ Event cards are one element with a full sentence label (title, summary, place, date, price,
  availability, saved state), the hint "Opens event details", and a custom **Save / Remove from
  saved** action (the heart is hidden from VoiceOver to avoid a duplicate stop).
- ✅ Decorative artwork and icons are hidden; meaningful artwork uses the organizer's `cover_alt`
  (editor asks for an image description).
- ✅ Glass controls have labels (Back, Save event, Share event, Notifications with unread count,
  Filters with active count, Close search).
- ✅ Category capsules expose `.isSelected`; calendar days announce the date and event count.
- ✅ Ticket code is read character by character; QR is labelled "Ticket QR code".
- ✅ Section headings carry the header trait; reading order follows the visual order.
- 📱 Full VoiceOver walkthrough on device (rotor, magic tap, Screen Recognition off).

## Dynamic Type

- ✅ All text uses text styles (`.body`, `.callout`, …) or `Font.custom(_:size:relativeTo:)`, so
  Sansita One scales with Dynamic Type.
- ✅ At accessibility sizes (≥ AX2) display titles switch to a heavy system serif
  (`DisplayStyle` fallback) to stay legible while keeping hierarchy.
- ✅ Controls scale with `@ScaledMetric` (capped) and keep a 44 pt minimum touch target.
- ✅ Metadata rows use `ViewThatFits` to stack vertically when space runs out; titles wrap
  instead of truncating where content matters.
- ✅ Large-text screenshots captured (see `VISUAL_QA.md`).

## Contrast & colour

- ✅ Primary text `#FFFFFF` on `#111110` (≈ 19:1) and on `#232321` (≈ 15:1).
- ✅ Secondary text is white at 62 % (≈ 7.5:1 on `#111110`); **Increase Contrast** raises it to
  82 % and dividers from 9 % to 24 %.
- ✅ Dark text `#111110` on the white primary capsule (≈ 19:1).
- ✅ Amber `#EDA71A` is used for accents and short warnings on dark (≈ 8.5:1), never as the only
  carrier of meaning: low availability also says "Only N left", unread items also have bold
  titles and an "Unread" accessibility value, ticket status has an icon and a label
  (**Differentiate Without Color**).

## Motion & transparency

- ✅ **Reduce Motion**: custom springs become short cross-fades (`ZunoMotion.adaptive`); shimmer
  becomes static; artwork settle, success pulse and QR spring are skipped. System zoom
  transitions, symbol effects and haptics adapt themselves.
- ✅ **Reduce Transparency**: custom Liquid Glass switches to `.identity` with a solid charcoal
  fill; system bars/sheets use the system's own frosted fallback.

## Input

- ✅ All actions are buttons/links (no gesture-only actions); swipe actions in lists have
  equivalent buttons or accessibility actions.
- ✅ iPad hardware keyboard: standard focus / tab navigation through native controls,
  `.submitLabel(.search)` on search.
- 📱 Switch Control and Voice Control pass.

## Haptics

- ✅ `.selection` for categories/filters/segments, `.impact(.light)` for search glass expansion,
  `.success` for registration, payment, favorite and valid check-in, `.warning` for low balance
  and low availability, `.error` for invalid tickets, failed payment and validation failures.
- 📱 Physical feedback must be felt on a device — the simulator has no Taptic Engine.

## Automated

- 🧪 UI tests drive every main flow through accessibility identifiers (17 tests).
- 🧪 Identifiers on screen containers use `.zunoContainer(_:)` so they never override the
  identifiers/labels of the controls inside them.
