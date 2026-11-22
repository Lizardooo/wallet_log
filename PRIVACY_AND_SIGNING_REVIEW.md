# Privacy and signing review

## Changes

SMS and SIM access now have an in-app explanation and an explicit choice before the Android permission prompt. Refusing SMS access leaves manual records and file import available. The underlying SMS parser, SIM routing, latest-balance logic, database schema and package identity are unchanged.

Dashboard sync now requires HTTPS, refuses redirects and asks for confirmation of the exact destination and data on every request. Full transaction message bodies are not sent unless selected for that request. Account numbers, transaction amounts, balances, parties and notes are still part of sync and are disclosed in the confirmation. The remote dashboard is not tested by these changes. Its support for omitted message bodies must be checked before production use.

Sync tokens move from legacy database settings to verified platform secure storage. A failed secure write never creates a new plaintext fallback. A legacy value is retained if migration fails, to avoid losing the owner's credential. It is removed after successful verified migration. In-app backups exclude both Gemini keys and sync tokens, including legacy plaintext settings. New backups also exclude the SMS consent flag so a restored copy asks again. Backups remain the same format and database version. Existing ZIP backups may still contain legacy sync tokens and should be kept private.

Android cloud backup and device-extraction rules exclude wallet data and credentials. The manual in-app ZIP backup is still available. OEM transfer behavior can differ; do not treat this as protection against a rooted device or physical forensic access. No existing wallet data is deleted by these rules.

## Unchanged AI behavior

Gemini configuration and model selection logic are unchanged. Model-list fetching in the AI tab retains its existing live probes. Model names or successful requests do not prove free pricing. No live Gemini calls were made during this change.

## Signing checkpoint

setup.sh generates the Android project with the existing com.example.wallet_log identity. The generated release build still uses Flutter's debug signing configuration. No private signing key is present in the source, no production key was generated and no signing certificate was replaced by this work. Separate CI runs can generate different debug keys.

Before installing an update, compare the installed app's signing certificate with the candidate APK. Do not uninstall the existing application to get around a mismatch. First make and verify an in-app backup and decide on a long-lived release-signing key and a data-preserving migration plan. A production certificate is a release-management requirement, not a guarantee of Play Protect acceptance.

## Play Protect boundary

Keeping READ_SMS can still trigger the sensitive-permission block for Internet downloads. These changes correct privacy handling; they do not disable, evade or promise removal of Play Protect. No external scanner upload or Google appeal was submitted. Any upload of a candidate APK to VirusTotal and any appeal need separate informed approval.

## References

- https://developers.google.com/android/play-protect/warning-dev-guidance
- https://developer.android.com/studio/publish/app-signing
- https://developer.android.com/identity/data/autobackup
- https://support.google.com/googleplay/android-developer/answer/10144311?hl=en
