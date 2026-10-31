#!/usr/bin/env bash
# One-time setup: generates the Android platform folder, installs the native
# Kotlin code (SMS reader + daily reminder), adds permissions and receivers,
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

# Replace the generated MainActivity with our native code.
KT_DIR=android/app/src/main/kotlin/com/example/wallet_log
find android/app/src/main -name 'MainActivity.*' -delete
mkdir -p "$KT_DIR"
cp native/*.kt "$KT_DIR/"

MANIFEST=android/app/src/main/AndroidManifest.xml

# App name (أموالي) and launcher icon.
sed -i 's|android:label="[^"]*"|android:label="أموالي"|' "$MANIFEST"
cp -r native/res/. android/app/src/main/res/

if ! grep -q POST_NOTIFICATIONS "$MANIFEST"; then
  awk '/<application/ { while ((getline l < "native/permissions.xml") > 0) print l } { print }' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
  awk '/<\/application>/ { while ((getline l < "native/receivers.xml") > 0) print l } { print }' \
    "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
fi

flutter pub get
echo "Done. Connect an Android phone and run: flutter run"
