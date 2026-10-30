#!/usr/bin/env bash
# One-time setup: generates the Android platform folder, adds SMS permissions,
# and fetches packages. Requires the Flutter SDK (https://flutter.dev/install).
set -euo pipefail

cp pubspec.yaml .pubspec.bak
cp -r lib .lib.bak
cp -r test .test.bak

flutter create --platforms=android --project-name wallet_log --org com.example .

mv -f .pubspec.bak pubspec.yaml
rm -rf lib test
mv .lib.bak lib
mv .test.bak test

MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q READ_SMS "$MANIFEST"; then
  # GNU sed syntax; on macOS use: brew install gnu-sed, then gsed.
  sed -i 's|<application|<uses-permission android:name="android.permission.READ_SMS"/>\n    <uses-permission android:name="android.permission.RECEIVE_SMS"/>\n    <application|' "$MANIFEST"
fi

flutter pub get
echo "Done. Connect an Android phone and run: flutter run"
