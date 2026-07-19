<p align="center">
  <img src="assets/icon/kurage_icon.png" width="120" alt="Kurage icon">
</p>

# Kurage

*[日本語版 README はこちら](README.md)*

A Mastodon client built with Flutter.
Targets Android / Web / Windows primarily; iOS / macOS / Linux are also buildable.

## Features

- **Multi-account / multi-column** — merge multiple accounts and timelines into a single column
- **Streaming (SSE)** — instant updates for new posts, with disconnect detection, automatic reconnect, and gap recovery for anything missed
- **Push notifications** — via FCM + a self-hostable Cloudflare Worker relay ([worker/](worker/))
- **Quote posts** — supports the official Mastodon 4.4 quote format, with a fallback compatible with Misskey / Fedibird
- Custom emoji & reactions, post translation, filters, lists, scheduled posts, drafts
- Grouped notifications, DMs (conversations), search, bookmarks & favourites lists
- **App lock** — PIN / biometric authentication (optional)
- **Full backup / restore** — move settings, columns and accounts to another device as JSON
- Boss key (the one-tap "disguise the screen" gag feature)
- Dark / light theme, adjustable theme colour, font and emoji size
- **English / Japanese UI** — follows the system locale by default; switchable in Settings → Appearance

<!-- TODO: add screenshots (place under docs/screenshots/ and reference here) -->

## Supported platforms

| Platform | Status |
|---|---|
| Android | ✅ Primary target. Distributed on Google Play |
| Web | ✅ Hosted at [kurage.demo2.jp](https://kurage.demo2.jp) |
| Windows | ✅ Installer / portable zip distributed via [GitHub Releases](https://github.com/demodemo0818/kurage/releases) |
| iOS / macOS / Linux | ⚠️ Buildable but untested and not distributed |

## Building

Requires: **Flutter SDK 3.41 or later** (Dart 3.11 or later)

```bash
git clone https://github.com/demodemo0818/kurage.git
cd kurage

# Copy the Firebase config templates (dummy values are enough to build and run)
cp lib/firebase_options.dart.example lib/firebase_options.dart
cp android/app/google-services.json.example android/app/google-services.json

flutter pub get
flutter run            # run on a connected device
flutter run -d chrome  # Web
flutter run -d windows # Windows desktop
```

- The app works fully with the dummy Firebase config (push notifications and Analytics are simply disabled).
- To use push notifications with your own setup, you'll need your own Firebase
  project and a self-hosted relay ([worker/](worker/)). See
  [PUSH_NOTIFICATION_SETUP.md](PUSH_NOTIFICATION_SETUP.md) and
  [worker/README.md](worker/README.md).
- The toolchain required for the Windows desktop build (Visual Studio 2022, etc.)
  is documented in the "Windows (desktop)" section of [CLAUDE.md](CLAUDE.md)
  (written in Japanese).
- [CLAUDE.md](CLAUDE.md) (Japanese) is also the most detailed reference for the
  architecture (state management, API layer, known pitfalls).

## Development

```bash
flutter analyze   # static analysis (kept at 0 issues)
flutter test      # unit tests
```

Bug reports and suggestions are welcome via Issues, in English or Japanese.
Please read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a PR.

## License

[Apache License 2.0](LICENSE)

The "Kurage" name and app icon are excluded from the Apache-2.0 license grant
(see Section 6 of the license). If you distribute a fork, please use a
different name and icon.
