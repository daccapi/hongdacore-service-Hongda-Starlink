# Hongda Core — 独立自研内核

Hongda Core 是鸿达星轨智连的**独立、干净室（clean-room）实现**的内核。

项目声明其不导入 sing-box 或 mihomo 的运行时代码；它实现兼容的命令行、配置
导入和 Clash HTTP/WebSocket 控制面。stdio JSON IPC 由 `HongdaService` 提供，
不属于 Core 本身。

## 架构

```text
cmd/hongda-core    命令行入口（version/features/check/run）
core/              运行时生命周期：Config -> Outbound/Group/Router/Inbound/API
model/             统一数据模型：Node/Outbound/Group/Rule/Config
protocol/          协议出站（direct / VLESS / Trojan / Hysteria2 / TUIC / Reality / uTLS / WS / gRPC）
strategy/          策略组（select / urltest）
route/             统一路由与流量统计
inbound/           入站（mixed：SOCKS5 + HTTP CONNECT）
api/               Clash 兼容控制面
telemetry/         流量与连接统计
config/            配置加载与格式识别
compat/singbox/     sing-box JSON 导入器（仅格式转换，不含上游代码）
```

## 构建与验证

```powershell
./build-windows.ps1
.\dist\HongdaCore.exe version
.\dist\HongdaCore.exe features
.\dist\HongdaCore.exe check -c config.json
.\dist\HongdaCore.exe run  -c config.json
```

默认构建脚本固定使用 Go 1.25.0，避免开发机上的 Go 自动升级造成不可复现的
Windows 网络运行时差异。

## 当前状态

已实现并可运行：

- `mixed` 入站（SOCKS5 无认证 + HTTP CONNECT）
- `mixed` 入站支持 SOCKS5 UDP ASSOCIATE（direct 出站 UDP 中继）
- `direct` 出站
- `vless` 出站（TCP + 基础 TLS + Reality + uTLS 指纹）
- `vless` 支持 `xtls-rprx-vision` 流控的 TCP padding 兼容层
- `vless` 支持 XUDP（Mux.Cool 单连接 UDP，默认启用，`packet_encoding: packetaddr` 可回退）
- `trojan` 出站（TCP + 基础 TLS + uTLS 指纹）
- `hysteria2` 出站（QUIC / HTTP3 认证，TCP + UDP datagram）
- `tuic` 出站（TUIC v5，QUIC + TLS Exporter 认证，TCP + UDP）
- `vless` / `trojan` 传输层：`ws`（WebSocket 客户端帧 + mask）与 `grpc`（gRPC-lite Gun 流）
- `vless` UDP over TCP（XUDP 或长度前缀帧）
- `trojan` UDP over TCP（命令 `0x03`，ATYP/addr/port/length 帧）
- REALITY（外借证书）客户端握手：X25519 ECDH + HKDF-SHA256 + AES-GCM SessionID
- uTLS 指纹（Chrome/Firefox/Safari/iOS/Edge/Android/Randomized 等）
- `select` / `urltest` 策略组
- Clash API：`/version`、`/proxies`、`/proxies/{name}`、`/connections`、`/traffic`
- `/traffic` 使用 Clash 兼容 WebSocket；`/connections` 返回实时累计字节
- 选择器切换后可通过 `DELETE /connections` 真正中断旧节点连接
- 规则路由：domain / domain_suffix / domain_keyword / ip_cidr / network / port / reject
- DNS over HTTPS 解析（`dns.mode=doh`，用于 IP 规则判定，并在 direct 出站时预解析以避免本地 DNS 泄漏）
- sing-box JSON 导入器（供现有 Flutter UI 兼容）
- 流量/连接统计

### 1.8.1 验证结果

- `go vet ./...` 与全量单元测试通过。
- 使用现有 VLESS + Reality + Vision 节点进行真实联网回归：HTTP CONNECT 与
  SOCKS5 各连续 5 轮通过，目标为 `https://www.gstatic.com/generate_204`。
- `check` 现在会拒绝尚未实现的 TUN、远程规则集、DNS 劫持等配置，不再静默
  丢弃后输出 `HONGDA_CHECK_OK`。

### 当前不能替换的功能

以下能力在 1.8.1 **尚未实现**，不能用功能声明或配置导入伪装为可用：

- Windows TUN 网卡、自动路由、strict route 与进程路由
- 远程 `.srs` 规则集、规则集匹配、FakeIP 与 DNS 劫持
- WireGuard / Tailscale

因此，当前 Windows 客户端开启 TUN 或远程规则集时仍应使用已有稳定内核；自研
Core 1.8.1 可先用于 mixed 系统代理模式。完成 TUN 前不要整体替换生产 Core。

## 路线图

1. ~~Reality（外借证书）与 uTLS 指纹~~
2. ~~VLESS Vision 流控与 UDP/XUDP~~（Vision padding 与 XUDP 均已实现）
3. ~~WebSocket / gRPC 传输~~（WebSocket 与 gRPC-lite 已实现，仍需服务端对等验证）
4. ~~Hysteria2 / TUIC（QUIC）~~（Hysteria2 与 TUIC 均已实现）
5. Windows TUN 网卡接管、自动路由与 strict route
6. DNS 劫持、FakeIP 与规则 DNS
7. 远程规则集与高级路由
8. WireGuard / Tailscale

详见 [CHANGELOG.md](CHANGELOG.md)、[docs/protocols.md](docs/protocols.md) 与
[docs/roadmap.md](docs/roadmap.md)。

## 许可

Hongda Core 采用独立实现，不含 GPL 上游代码。详见 [NOTICE.md](NOTICE.md)。
