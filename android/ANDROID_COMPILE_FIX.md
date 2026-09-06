# Android compile fix

- Fixed `TextFormField` callback in `lib/src/android_app.dart`: `onSubmitted` -> `onFieldSubmitted`.
- `tools/build-android-release.ps1` now checks native command exit codes and will not print a false success message when Flutter/Gradle fails.
- Gradle 8.13 / Kotlin 2.2.0 warnings are intentionally left unchanged in this patch because they are warnings, not the current build blocker.
