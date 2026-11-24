# Mihrap for iPhone and iPad (native)

A native Swift (UIKit) port of the Mihrap Android app (`mihrap-android`), screen by screen.

- `Mihrap/` — Swift sources: prayer times (Diyanet via ezanvakti), home screen, adhan with mosque photos,
  settings, location picker, prayer schedule, silent notifications at prayer times.
- `Mihrap/Resources/` — Android strings for 10 languages, fonts and home photos, made by `prepare_resources.py`
  from the Android project (`../salahwin`).
- Adhan recordings and photos are downloaded from the `tefekkur-assets` releases, like the Android app.

## Build

GitHub Actions (`.github/workflows/build.yml`) builds an unsigned `Mihrap.ipa` on macOS for every push.
Install it with Sideloadly (it signs the app with your Apple ID; a free Apple ID needs re-signing every 7 days).

The earlier web-wrapper app is kept in the separate `mihrap-ios` repository.
