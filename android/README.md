# 鸿达星轨智连 Android V1.6.5（R9 / HongdaCore）

鸿达星轨智连的 Android Flutter 客户端。R9 使用 Android `VpnService` 建立真实 TUN，并通过自有桥接名称 `HongdaCore.aar` 调用固定版本的 sing-box `experimental/libbox`。

## 运行架构

```text
Flutter UI
  -> MethodChannel(hongda_starlink/android)
  -> MainActivity / HongdaVpnService
  -> HongdaCore.aar (com.hongda.starlink.core.libbox)
  -> libhongdacore.so
  -> sing-box 1.13.18 experimental/libbox
  -> VLESS / Reality / Hysteria2 / Clash API
```

`HongdaVpnService` 负责 VPN 授权、前台服务、TUN、路由、`protect(fd)`、底层网络、DNS 和生命周期；Flutter 负责节点、订阅、配置生成及状态展示。连接成功以 Native/Core 实际状态为准，不伪造成功状态。

## V1.6.5 更新

- 节点列表和最近节点按名称、服务器及标签识别国家/地区，并显示国旗与中文国家名。
- 订阅刷新按节点身份和端点匹配，保留收藏、启用状态、延迟与节点 ID。
- 修复 Service/Core 已运行但 Flutter 重启后界面显示未连接的问题。
- 修复 Native 启动失败后前台 Service 残留，以及正常停止后状态不同步的问题。
- Clash `/traffic` WebSocket 增加断线重连保护；无有效流量帧时使用 `/connections` 增量作为回退，手工 VLESS 节点同样显示流量。
- Mixed 与 Clash API 端口不再强制固定；首选端口被占用时自动选择可用端口，并把实际端口同步到配置和界面。
- R9 强制使用 TUN 接管；关闭容易造成误解的 Android“系统代理”开关，并锁定已验证的 strict-route/IPv6 组合。
- Android 备份关闭，降低 VPN 配置和本地节点数据进入系统备份的风险。

完整记录见 `CHANGELOG.md`。

## 构建

环境要求：Flutter 3.44+、Java 17+、Android SDK/NDK。构建 AAR 还需要 Go 与 gomobile。

```powershell
# 使用已有 android/app/libs/HongdaCore.aar 构建 APK
powershell -ExecutionPolicy Bypass -File .\tools\build-android-release.ps1

# 从源码重新生成 HongdaCore.aar
powershell -ExecutionPolicy Bypass -File .\tools\build-android-core.ps1
```

详细说明见 `BUILD_ANDROID.md`。本项目当前 release 配置使用本机调试签名，仅适合个人测试；正式分发前应换成自己的 release keystore。

## 数据与日志

应用数据保存在 Android 应用沙箱中；卸载应用或清除应用数据会删除节点、订阅与设置。运行日志可在应用“日志”页面及 `adb logcat` 中查看。

## 第三方源码与许可

`HongdaCore` 是本项目的桥接和产物名称，不表示底层协议实现完全原创。`core/sing-box` 及其衍生二进制继续受上游许可证约束；源码包保留相应许可证、版权声明和修改说明。可删除构建缓存与重复产物，但不能用改名替代许可证义务。
