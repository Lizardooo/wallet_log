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

# The SMS plugin configures Kotlin tasks after the root project is evaluated.
# Apply the target to every subproject so the plugin's 1.8 default matches the
# Java 11 target used by the generated app.
cat >> android/build.gradle.kts <<'EOF'

subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
        }
    }
}
EOF

flutter pub get
echo "Done. Connect an Android phone and run: flutter run"
