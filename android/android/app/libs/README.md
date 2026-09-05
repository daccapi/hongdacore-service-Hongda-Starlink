# Android sing-box core

Place the Android sing-box `libbox.aar` matching your chosen sing-box version in this directory, then uncomment the `implementation(files("libs/libbox.aar"))` dependency in `android/app/build.gradle.kts` and bind its API inside `HongdaVpnService.kt`.

The old Windows `HongdaService.exe` is intentionally not used on Android.
