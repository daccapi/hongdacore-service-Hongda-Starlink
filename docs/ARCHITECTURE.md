# 架构与历史来源

## Windows 当前基线

```text
windows/ Flutter UI
  -> windows/service/ HongdaService 1.5.12
    -> hongda-core/ HongdaCore 1.10.12
      -> 协议出站 / DNS / Router / Clash-compatible API
      -> tunnel/ Windows TUN 适配 -> sing-tun + gVisor + Wintun
```

Core 的配置导入支持 sing-box 格式，不代表每个当前 Core 协议实现都调用 sing-box。
TUN 底层使用第三方组件，不能将其说成完全原创。早期 Windows 包使用过 sing-box 内嵌核心，
与今天的 Windows Core 架构不同，历史 Releases 中均明确区分。

## Android 历史基线

```text
android/lib/ Flutter UI
  -> MethodChannel
    -> android/android/ Kotlin HongdaVpnService
      -> HongdaCore.aar / libhongdacore.so
        -> android/core/sing-box/ experimental/libbox
```

Android 的 AAR/so 名字是产物名称，底层仍为 sing-box 派生源码。当前归档 Android 版本
是 V1.6.5 / R9，不把 Windows Core 1.10.12 的能力或验证结果套用到 Android 上。
