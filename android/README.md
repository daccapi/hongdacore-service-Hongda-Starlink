# 鸿达星轨智连 V1.6.3 — Bugfix 源码

Windows-only Flutter 桌面网络客户端。本版本是在 V1.6.2 Responsive Dashboard 基础上对启动链、Service 生命周期、配置生成、系统代理恢复、数据持久化和窗口响应式布局进行稳定性修复。

## 目标环境

```text
Flutter 3.44.4 Stable
Dart    3.12.2
Go      1.23+（源码包内 Service 由 Go 1.23.2 windows/amd64 交叉构建）
Windows 10/11 x64
sing-box 1.13.18 Windows amd64
```

## 当前运行架构

```text
HongdaStarlink.exe
  ├─ Flutter Windows UI
  ├─ 节点 / 订阅 / URLTest / 规则组 / 路由 / TUN / DNS
  ├─ Windows 原生窗口与系统代理 MethodChannel
  └─ runtime\service\HongdaService.exe 1.4.1
       ├─ supervisor / JSON-lines IPC
       ├─ embedded official sing-box.exe 1.13.18
       └─ embedded libcronet.dll
```

Flutter 只直接启动 `HongdaService.exe`。Service 首次运行时校验并释放内嵌官方 sing-box 与 libcronet 到：

```text
%LOCALAPPDATA%\HongdaStarlink\runtime\1.13.18\
```

随后先执行 `sing-box check`，再启动 core。运行中的 sing-box 会被加入 kill-on-close Windows Job Object，因此 Service 被异常结束时不会故意留下孤儿 core。

## V1.6.3 重点修复

- 修复 Service 具体错误被 `phase=service` 二次错误覆盖的问题；一个故障只保留一个结构化 `HONGDA_ERROR`。
- Flutter 错误选择增加 phase 优先级，`config_check` / `core_start` / `core_supervision` 等具体错误不会再被泛化错误覆盖。
- 启动失败先通过 IPC 请求 `stop`，超时后才强制结束；Service 为 sing-box 子进程增加 kill-on-close Job Object。
- 修复空规则组未生成 outbound、但路由仍引用该 tag 导致 `sing-box check` 失败的问题。
- Sing-box / Clash 导入支持递归解析嵌套组，并尽量保留规则指向的具体节点。
- 节点去重 fingerprint 纳入完整 outbound 配置，减少同服务器/端口不同 Reality、TLS、transport 参数被误去重。
- 未连接时的裸 TCP 探测不再伪装成代理 URLTest 延迟，只标记“TCP 端口可达”。
- Windows 系统代理增加崩溃恢复快照；下次启动时只在代理仍精确指向鸿达记录的地址时恢复原设置，避免覆盖用户后来手工设置的代理。
- Dashboard 移除固定 1280 宽整页 `FittedBox(scaleDown)`，改为宽 / 中 / 窄三档真实响应式重排。
- Windows 最小窗口调整为 760×520，普通窗口模式可使用真实窄布局。
- JSON 数据保存增加串行写队列、`.bak` / `.tmp` 恢复，降低重叠写和异常退出导致配置丢失的风险。

详细变化见 `V1.6.3_BUGFIX_CHANGELOG.md`。

## 已验证的 Service

```text
Service version: 1.4.1
Size:            57,331,712 bytes
SHA256:          caecf6bd617bd96d1c2c4b820b16b2361d620f39fa6a5177448b704fcdbab778
Core:            sing-box 1.13.18
Core SHA256:     140c46d667d16b1491f6b830812e846c25aa2b18e68bd695023c69c393ad7081
```

Go 侧已通过：

```text
go test ./...
GOOS=windows GOARCH=amd64 go test ./...
```

本审查环境未安装 Flutter/Dart SDK，因此源码包交付前未在此环境执行完整 `flutter build windows --release`；请在 Windows Flutter 环境按 `BUILD_WINDOWS.md` 构建。

## 本地数据位置

```text
%APPDATA%\HongdaStarlink\nodes.json
%APPDATA%\HongdaStarlink\settings.json
%APPDATA%\HongdaStarlink\subscriptions.json
%APPDATA%\HongdaStarlink\groups.json
%APPDATA%\HongdaStarlink\rules.json
%APPDATA%\HongdaStarlink\traffic.json
```

重新解压源码或重新编译不会主动清空上述数据。

## 构建

见 `BUILD_WINDOWS.md`。
