# Hongda Android Core

`HongdaCore.aar` is intentionally generated from the vendored sing-box v1.13.18 source.

Build from the project root:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-core.ps1
```

The build uses:

- AAR: `HongdaCore.aar`
- gomobile Java prefix: `com.hongda.starlink.core`
- generated Java package: `com.hongda.starlink.core.libbox`
- native library: `libhongdacore.so`
- default ABI: `arm64-v8a`

Use `-AllAbis` to build a multi-ABI AAR.
