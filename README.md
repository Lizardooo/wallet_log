# Wallet Log

Flutter (Android) app that reads your wallet SMS messages and keeps one
searchable transaction log across Vodafone Cash, InstaPay, Orange Cash and
Etisalat Cash / Fawry.

- Scans your SMS inbox whenever you open the app (pull down or tap refresh to rescan).
- Shows monthly in / out / net totals and a per-wallet filter.
- Everything is stored locally on the phone (SQLite). Nothing is uploaded.

## Setup

1. Install the Flutter SDK.
2. Run `./setup.sh` (generates the `android/` folder, adds the SMS
   permissions, runs `flutter pub get`).
3. Plug in an Android phone with USB debugging on and run `flutter run`.

If the build complains about `minSdk`, set it to 23 in
`android/app/build.gradle(.kts)`.

## Tuning the parser

E-wallet SMS templates vary and change over time. The parsing rules live in
`lib/parser.dart` (keywords for incoming / outgoing, wallet detection). Paste a
few real messages (with names and numbers redacted) into
`test/parser_test.dart`, run `flutter test`, and adjust until they pass.

## Limits

- Android only: iOS does not allow apps to read SMS.
- Messages are read when the app is opened, so nothing is missed, but the log
  does not update while the app is closed.
- SMS access uses a small piece of native code (`native/MainActivity.kt`, copied
  into the Android project by `setup.sh`) instead of a third-party plugin.
