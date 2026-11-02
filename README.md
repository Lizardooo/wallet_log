# أموالي (Amwali)

Flutter (Android) app for a currency trader who receives many transfers on
several wallet numbers (Vodafone Cash, InstaPay, Orange Cash, Etisalat Cash /
Fawry). It reads the wallet SMS messages and keeps one transaction log.
Everything is stored locally on the phone (SQLite). Nothing is uploaded, except
the SMS texts you choose to send to Google when you run the AI classification.

## First run (إعداد أول مرة)

Opening the app for the first time shows a short setup instead of the tabs:

1. **شرائحك ومحافظك** - the app lists the phone's SIMs with their slot, carrier
   and number when the phone reports it. Tick each number that carries a wallet
   and choose its wallet type(s); type the number by hand when it is not
   detected. Only messages for the chosen wallets are stored.
2. **الذكاء الاصطناعي** - optional: paste a Gemini API key, let the app list the
   free models available to that key, and pick one.

Finishing (or "تخطي الآن") stores the setup and opens the **التقارير** tab.
Wallet numbers can still be added or edited later in **الحسابات**.

## Screens (Arabic, right-to-left)

- **المعاملات** - every wallet operation, grouped by day with in / out / fee
  totals. Filters: wallet number, operation type (transfer, cash in, cash out,
  phone top-up, bills and services, merchant payments, refunds, fees) and a date
  range (today, yesterday, 7 days, this month, or any custom range). Tap a
  transaction to see the original SMS, correct its type / direction and add a
  remark. Transactions analysed by the model show its one-line reasoning.
- **اليومي** - per wallet number and per day: opening balance, in, out and the
  expected remaining. It is compared with the last balance printed in that day's
  SMS and flags any difference. The **إظهار معاملات اليوم** switch lists each
  wallet's transactions for that day under its summary, or hides them; the
  choice is remembered.
- **التقارير** - totals by wallet number and the busiest counterparty numbers,
  for today / 7 days / 30 days / this month / all, plus **Excel import**.
- **الحسابات** - add your own wallet numbers on this phone, and turn on the
  daily reminder notification.
- **الذكاء** - Gemini key, free model picker, and the "classify my messages"
  action with progress and results.

### Filters

- Only one date shortcut is selected at a time, even on the first day of the
  month when "today" and "this month" cover the same dates.
- Today, yesterday, 7 days and 30 days use local calendar days. "This month"
  means the first of the current month through the end of today. Custom ranges
  include both selected days. "All" removes the date restriction.
- Wallet, operation type, date and in/out filters combine. Multiple operation
  types are alternatives within the type filter. "Clear all" also resets in/out.
- The main transactions view contains confirmed operations; pending or unknown
  operations remain in the separate review view, still filtered by wallet,
  type and date. A month with no confirmed operations can legitimately be empty.
- The list summary and transaction Excel export follow the visible filters.
  Report export follows the report's selected wallet and period, including
  pending rows with their status (their amounts remain excluded from totals).

### Accuracy safeguards

- OTP / temporary-code, failed, rejected, pending and promotional messages are
  ignored, and balance, limit and fee amounts are separated from the amount.
- Only **transfers** and explicit **deductions** (خصم / debited) are counted
  automatically. Every other operation (cash in/out, top-up, bills, merchant
  payments, refunds, fees without a deduction, anything unclear) is flagged
  "تحتاج مراجعة" and stays out of all totals until you open it and press
  "تأكيد واحتساب". Nothing is guessed.
- Any message containing "وخصم X من محفظتك" is counted as money that left the
  wallet, and X is the amount taken (even if the message also mentions a
  transfer, top-up or bill).
- Each message's printed balance is checked against the previous one; a gap
  flags a missing / deleted message or a mis-read amount.
- Corrections you make are never overwritten by later scans, and never
  overwritten by the model either.
- The SMS templates are not public, so the rules were built from the operations
  Egyptian wallets offer, not from real messages. Send real samples to tune them.

### Opening balance

Each day the app asks for every wallet's opening balance (a dialog on opening
the app, plus an optional push notification at a time you choose). The field is
pre-filled with the last balance seen in the SMS before that day.

### Linking messages to wallet numbers

Messages are matched to a wallet number by wallet type. If one phone has two
numbers of the same type (dual SIM), the SIM chosen during setup (or in
**الحسابات**) decides which number a message belongs to. When wallet numbers
are chosen during setup, messages for wallet types that were not chosen are
skipped.

## AI classification (Gemini)

1. Create an API key at <https://aistudio.google.com/apikey>.
2. Paste it in **الذكاء** (or in the setup wizard) and press
   **جلب الموديلات المجانية**. The app asks Google which models the key can use,
   hides non-text models, and marks the free-tier families (flash / flash-lite /
   gemma). Pick one; **عرض الكل** shows the rest.
3. Press **تصنيف الغامضة** to send only the messages that need review, or
   **تصنيف الكل** for everything.

The model is prompted as an expert financial analyst for Egyptian wallets. It
returns a type, a direction, a confidence and a short reason per message, as
JSON. Classifications with confidence below 0.6, or without a direction, stay in
"تحتاج مراجعة" so no amount enters the totals by mistake. The result is stored
on the transaction (`ai` / `ai_note`), so the SMS scan never re-parses it away.

Messages are sent in batches of 10. Requests go to
`generativelanguage.googleapis.com` only while you run a classification; the key
and the model are stored on the phone.

## Excel import

In **التقارير**, press **استيراد تقرير Excel (.xlsx)**:

- `.xlsx` only (export from Excel or Google Sheets); `.xls` and CSV are rejected
  with a message.
- The first sheet rows are scanned for a header. Recognized titles (Arabic or
  English): التاريخ / date, المبلغ / amount, نوع العملية / type,
  الاتجاه / direction, رقم المحفظة / wallet, البيان أو الوصف / description,
  الرسوم / fee, الطرف الآخر أو رقم الهاتف / party. Without a header the app
  assumes: date, amount, type, description.
- Sheets, recognized columns, the number of rows and a short preview are shown
  before anything is saved.
- **الملف جاي من أي محفظة؟** - once wallets are set up, the import dialog asks
  which wallet the file belongs to (required). Every row is linked to that
  wallet, overriding any wallet column in the file, so reports from several
  phones can be collected on one phone and each appears under its own number
  in **اليومي**. The same rows imported for two different wallets are kept
  apart; importing again for the same wallet adds nothing.
- Amounts may be `1,250.50`, `١٢٥٠٫٥`, `(300)` or `-300 جنيه`. Dates may be real
  date cells, `2026-10-01`, `02/10/2026 14:30` or an Excel serial number. Rows
  without a date take the date of the row above.
- Rows with no amount and obvious totals rows ("الإجمالي", "total") are skipped.
- Imported rows are marked as hand-entered, so re-reading the inbox never
  re-classifies them, and importing the same file twice adds nothing.

## Setup

1. Install the Flutter SDK.
2. Run `./setup.sh` (generates `android/`, installs the native Kotlin code from
   `native/`, adds permissions and receivers, runs `flutter pub get`).
3. Plug in an Android phone with USB debugging on and run `flutter run`.

Pushing to GitHub also builds the APK (Actions tab, artifact `wallet-log-apk`).

## Tuning the parser

SMS templates vary and change. The rules are in `lib/parser.dart`. Add a few
real messages (names and numbers redacted) to `test/parser_test.dart`, run
`flutter test`, and adjust until they pass. The Excel importer and the model
answer parsing have their own tests in `test/importer_test.dart` and
`test/gemini_test.dart`.

## Limits

- Android only: iOS does not allow apps to read SMS.
- Messages are read when the app is opened, not while it is closed.
- Each phone keeps its own data. Combining several phones on one dashboard needs
  a shared server and is not built yet.
- SMS access and the reminder use native code in `native/` instead of
  third-party plugins; the file picker (`file_selector`) and the Excel reader
  (`excel`) are the only package additions.
- The AI step needs internet and a valid key, and free quotas are limited per
  model per day.
