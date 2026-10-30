# Wallet Log

Flutter (Android) app for a currency trader who receives many transfers on
several wallet numbers (Vodafone Cash, InstaPay, Orange Cash, Etisalat Cash /
Fawry). It reads the wallet SMS messages and keeps one transaction log.
Everything is stored locally on the phone (SQLite). Nothing is uploaded.

## Screens (Arabic, right-to-left)

- **المعاملات** - transactions grouped by day with daily in/out totals. Tap a
  transaction to add or edit a remark. Filter by wallet number.
- **اليومي** - per wallet number and per day: opening balance, in, out and the
  expected remaining. It is compared with the last balance printed in that day's
  SMS and flags any difference.
- **التقارير** - totals by wallet number and the busiest counterparty numbers,
  for today / 7 days / 30 days / this month / all.
- **الحسابات** - add your own wallet numbers on this phone, and turn on the
  daily reminder notification.

### Opening balance

Each day the app asks for every wallet's opening balance (a dialog on opening
the app, plus an optional push notification at a time you choose). The field is
pre-filled with the last balance seen in the SMS before that day.

### Linking messages to wallet numbers

Messages are matched to a wallet number by wallet type. If one phone has two
numbers of the same type (dual SIM), pick the SIM when adding the account.

## Setup

1. Install the Flutter SDK.
2. Run `./setup.sh` (generates `android/`, installs the native Kotlin code from
   `native/`, adds permissions and receivers, runs `flutter pub get`).
3. Plug in an Android phone with USB debugging on and run `flutter run`.

Pushing to GitHub also builds the APK (Actions tab, artifact `wallet-log-apk`).

## Tuning the parser

SMS templates vary and change. The rules are in `lib/parser.dart`. Add a few
real messages (names and numbers redacted) to `test/parser_test.dart`, run
`flutter test`, and adjust until they pass.

## Limits

- Android only: iOS does not allow apps to read SMS.
- Messages are read when the app is opened, not while it is closed.
- Each phone keeps its own data. Combining several phones on one dashboard needs
  a shared server and is not built yet.
- SMS access and the reminder use native code in `native/` instead of
  third-party plugins.
