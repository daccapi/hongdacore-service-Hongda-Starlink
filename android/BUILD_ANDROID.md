# 鸿达星轨智连 Android V1.6.5 构建

## 基线

```text
Flutter UI                 V1.6.5+165
Android Service            HongdaVpnService
Android Core AAR           HongdaCore.aar
Native library             libhongdacore.so
Java package               com.hongda.starlink.core.libbox
sing-box source            1.13.18 experimental/libbox
minSdk                     24
default ABI                arm64-v8a
```

## 构建 HongdaCore

双击 `BUILD-ANDROID-CORE.cmd`，或执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-core.ps1
```

生成 `android\app\libs\HongdaCore.aar`。脚本验证 AAR 内同时存在：

```text
com/hongda/starlink/core/libbox/Libbox.class
libhongdacore.so
```

生成全部 Android ABI：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-core.ps1 -AllAbis
```

## 构建 APK

双击 `BUILD-ANDROID-RELEASE.cmd`，或执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-release.ps1
```

默认构建 arm64 Release APK。当前 release 使用本机调试签名，适合个人安装测试；对外分发前必须配置自己的 release keystore。

## 环境

- Flutter 3.44+
- Java 17+
- Go 1.24.7+（仅重建 AAR 时需要）
- Android SDK
- Android NDK 28.0.13004108 或兼容版本

脚本在缺少 SagerNet gomobile 时会安装固定版 `v0.1.12`。

## 运行链

```text
Flutter Android UI
  -> MethodChannel(hongda_starlink/android)
  -> MainActivity.kt
  -> HongdaVpnService.kt
  -> HongdaCore.aar
  -> libhongdacore.so
  -> sing-box 1.13.18 experimental/libbox
```

Service 执行配置检查、CommandServer 启动和 TUN 建立。节点切换优先使用 Clash API 热切换，失败时重载 Core。实时流量优先读取 `/traffic`，不可用时用 `/connections` 的连接累计量增量回退。

Mixed 与 Clash API 配置值是首选端口。若被占用，启动器会自动尝试相邻端口，仍不可用时由系统分配空闲端口；生成配置、API 客户端和状态页面始终使用同一组实际端口。

## 第三方说明

`HongdaCore.aar` 和 `libhongdacore.so` 是本项目产物名称。底层 sing-box 源码和衍生物继续保留上游许可证与版权声明。
