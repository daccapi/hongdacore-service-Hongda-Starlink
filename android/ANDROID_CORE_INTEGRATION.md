# Android Core 集成说明

本工程不再使用 Windows 的 `HongdaService.exe`。Android 对应层如下：

| Windows | Android |
|---|---|
| `HongdaService.exe` | `HongdaVpnService.kt` |
| embedded `sing-box.exe` | `HongdaCore.aar` / `libhongdacore.so` |
| Windows admin/TUN | Android `VpnService` permission |
| stdio IPC | Flutter MethodChannel |
| Clash API metrics | Clash API metrics（同一套业务） |

为了便于继续跟进官方 sing-box，`experimental/libbox` 本体保持上游结构，不粗暴改包目录。鸿达化在 gomobile bind 输出层完成：

```text
-o HongdaCore.aar
-javapkg=com.hongda.starlink.core
-libname=hongdacore
./experimental/libbox
```

因此最终 native 名称为 `libhongdacore.so`，Java 绑定位于 `com.hongda.starlink.core.libbox`。
