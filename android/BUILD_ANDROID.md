# 鸿达星轨智连 V1.6.4 R2 Android Core 构建

本版已把 Android 第一版从“只有 VpnService 壳”推进到真实 Core Bridge：

- Windows 业务基线：V1.6.4-R2-RegressionFix
- Android VPN Service：`HongdaVpnService.kt`
- Android Core AAR：`HongdaCore.aar`
- Native library：`libhongdacore.so`
- Java package prefix：`com.hongda.starlink.core`
- gomobile 生成包：`com.hongda.starlink.core.libbox`
- sing-box 源码：固定 `v1.13.18`
- 默认 ABI：`arm64-v8a`
- minSdk：24

## 1. 构建 HongdaCore

项目根目录双击：

`BUILD-ANDROID-CORE.cmd`

或执行：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-core.ps1
```

生成：

`android\app\libs\HongdaCore.aar`

脚本会验证 AAR 中同时存在：

- `com/hongda/starlink/core/libbox/Libbox.class`
- `libhongdacore.so`

如果要一次生成全部 Android ABI：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-core.ps1 -AllAbis
```

## 2. 构建 APK

双击：

`BUILD-ANDROID-RELEASE.cmd`

或：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-android-release.ps1
```

默认只构建 arm64 Release APK。

## 3. 环境

- Flutter 3.44+
- Go 1.24.7+（Go 1.26.x 可用）
- Android SDK
- Android NDK（官方 sing-box 构建器优先 28.0.13004108，也可使用已安装的最新 NDK）
- Java 17+

脚本会在缺少 SagerNet gomobile 时安装固定版 `v0.1.12`。

## 4. 运行链

```text
Flutter Android UI
  -> MethodChannel(hongda_starlink/android)
  -> MainActivity.kt
  -> HongdaVpnService.kt
  -> HongdaCore.aar
  -> libhongdacore.so
  -> sing-box experimental/libbox
```

`HongdaVpnService` 会真实执行 `Libbox.checkConfig`、`CommandServer.start()`、`startOrReloadService()`，并通过 Android `VpnService.Builder` 建立 TUN；不会伪造连接成功。

## 5. 已复用 R2 Windows 业务

共享的节点模型、订阅解析、配置导入、规则组、sing-box 配置生成器继续共用；本包同步了 R2 的 selector/节点切换相关业务及 172.19 TUN/DNS 回归修复。Android 连接中切换节点优先走 Clash API 热切换，失败时自动重载 Core。

实时上传/下载和活动连接数直接复用 Clash API `/traffic` WebSocket 与 `/connections`，不再使用 native 假数据。
