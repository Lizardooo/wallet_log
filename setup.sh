#!/usr/bin/env bash
# One-time setup: generates the Android platform folder, installs the native
# Kotlin code (SMS reader + daily reminder), adds permissions and receivers,
# and fetches packages. Requires the Flutter SDK (https://flutter.dev/install).
set -euo pipefail

# `flutter create .` overwrites pubspec.yaml, lib/ and test/ with templates. Keep
# copies and put them back, even if the command fails half way. Refuse to start
# if a previous run left backups behind, so good backups are never overwritten.
for b in .pubspec.bak .lib.bak .test.bak; do
  if [ -e "$b" ]; then
    echo "Found leftover $b from an earlier run. Restore from it or remove it, then retry." >&2
    exit 1
  fi
done

cp pubspec.yaml .pubspec.bak
cp -r lib .lib.bak
cp -r test .test.bak

restore() {
  [ -e .pubspec.bak ] && mv -f .pubspec.bak pubspec.yaml
  if [ -d .lib.bak ]; then rm -rf lib; mv .lib.bak lib; fi
  if [ -d .test.bak ]; then rm -rf test; mv .test.bak test; fi
}
trap restore EXIT

flutter create --platforms=android --project-name wallet_log --org com.example .
restore
trap - EXIT

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

# flutter_secure_storage needs minSdk 23 or higher; never go below it.
for g in android/app/build.gradle.kts android/app/build.gradle; do
  [ -f "$g" ] || continue
  sed -i -E 's/minSdk(Version)? *=? *flutter\.minSdkVersion/minSdk = maxOf(flutter.minSdkVersion, 23)/' "$g"
  if [ "${g##*.}" = "gradle" ]; then
    sed -i -E 's/minSdk = maxOf\(flutter\.minSdkVersion, 23\)/minSdkVersion Math.max(flutter.minSdkVersion, 23)/' "$g"
  fi
done

flutter pub get
echo "Done. Connect an Android phone and run: flutter run"
