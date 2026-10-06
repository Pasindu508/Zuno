# Zuno — Localization

## Status

| Language | Code | Status |
|---|---|---|
| English (Sri Lanka) | `en` / `en_LK` | complete (source language) |
| Sinhala | `si` / `si_LK` | ready for translation — declared in `CFBundleLocalizations` |
| Tamil | `ta` / `ta_LK` | ready for translation — declared in `CFBundleLocalizations` |

## How strings are written

* Every user-facing string goes through `LocalizedStringKey` (`Text("…")`, `Button("…")`) or
  `String(localized:)`; there are no hard-coded `Text(verbatim:)` sentences except brand names
  and language names shown in their own script ("සිංහල", "தமிழ்").
* Plurals use Foundation's automatic grammar agreement, e.g.
  `"^[\(count) free registration](inflect: true) left this month"`.
* `SWIFT_EMIT_LOC_STRINGS = YES` and `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`; strings are
  collected into `Zuno/Resources/Localizable.xcstrings` when building in Xcode.
* Export for translators:

  ```bash
  xcodebuild -exportLocalizations -project Zuno.xcodeproj -localizationPath build/loc -exportLanguage si -exportLanguage ta
  ```

  Import the translated `.xcloc` with `xcodebuild -importLocalizations`.

## Formats

* Currency: `ZunoFormat.currency` → `LKR 1,500.00` (always cents for non-whole amounts; minus
  sign U+2212 for debits). PayHere amounts use plain `1500.00`.
* Dates and times: `Asia/Colombo` time zone everywhere, Gregorian calendar, Monday first,
  `en_LK` / `si_LK` / `ta_LK` locale following the app's active localization.
* Mobile numbers: Sri Lankan `07X XXX XXXX` input normalised to E.164 `+947XXXXXXXX`.
* Locations: the 25 districts with principal cities (`SriLankaLocations`).

## Fonts

Sansita One covers Latin only. When a title is in Sinhala or Tamil, iOS falls back to the system
font for those glyphs automatically; translators should keep event titles short.

## Right-to-left readiness

Layouts use leading/trailing alignment, SF Symbols (which mirror automatically where
appropriate) and no fixed coordinates, so an RTL pseudo-language renders correctly. Zuno's
target languages are left-to-right.
