# Hongda Core — 独立自研内核

Hongda Core 是鸿达星轨智连的**独立、干净室（clean-room）实现**的内核。

它**不导入、不复制 sing-box 或 mihomo 的 GPL 代码**，只实现相同的命令行、
stdio IPC 与 Clash 兼容 HTTP 表面，以便现有的 `HongdaService` 和 Flutter UI
可以无缝驱动。

## 架构

```text
cmd/hongda-core    命令行入口（version/features/check/run）
core/              运行时生命周期：Config -> Outbound/Group/Router/Inbound/API
model/             统一数据模型：Node/Outbound/Group/Rule/Config
protocol/          协议出站（direct / VLESS / Trojan / Hysteria2 / Reality / uTLS / WS / gRPC）
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
go build -o HongdaCore.exe ./cmd/hongda-core
.\HongdaCore.exe version
.\HongdaCore.exe features
.\HongdaCore.exe check -c config.json
.\HongdaCore.exe run  -c config.json
```

## 当前状态

已实现并可运行：

- `mixed` 入站（SOCKS5 无认证 + HTTP CONNECT）
- `mixed` 入站支持 SOCKS5 UDP ASSOCIATE（direct 出站 UDP 中继）
- `direct` 出站
- `vless` 出站（TCP + 基础 TLS + Reality + uTLS 指纹）
- `vless` 支持 `xtls-rprx-vision` 流控的 TCP padding 兼容层
- `trojan` 出站（TCP + 基础 TLS + uTLS 指纹）
- `hysteria2` 出站（QUIC / HTTP3 认证，TCP + UDP datagram）
- `vless` / `trojan` 传输层：`ws`（WebSocket 客户端帧 + mask）与 `grpc`（gRPC-lite Gun 流）
- `vless` UDP over TCP（命令 `0x02`，长度前缀帧）
- `trojan` UDP over TCP（命令 `0x03`，ATYP/addr/port/length 帧）
- REALITY（外借证书）客户端握手：X25519 ECDH + HKDF-SHA256 + AES-GCM SessionID
- uTLS 指纹（Chrome/Firefox/Safari/iOS/Edge/Android/Randomized 等）
- `select` / `urltest` 策略组
- Clash API：`/version`、`/proxies`、`/proxies/{name}`、`/connections`、`/traffic`
- 规则路由：domain / domain_suffix / domain_keyword / ip_cidr / network / port / reject
- DNS over HTTPS 解析（`dns.mode=doh`，用于 IP 规则判定，并在 direct 出站时预解析以避免本地 DNS 泄漏）
- sing-box JSON 导入器（供现有 Flutter UI 兼容）
- 流量/连接统计

## 路线图

1. ~~Reality（外借证书）与 uTLS 指纹~~
2. ~~VLESS Vision 流控与 UDP/XUDP~~（Vision padding 已实现，XUDP 待补）
3. ~~WebSocket / gRPC 传输~~（WebSocket 与 gRPC-lite 已实现，仍需服务端对等验证）
4. ~~Hysteria2 / TUIC（QUIC）~~（Hysteria2 已实现，TUIC 待补）
5. WireGuard / Tailscale
6. TUN 网卡接管与 split routes
7. DNS（DoH / fakeip / 规则 DNS）
8. 完整路由规则与规则集

详见 [CHANGELOG.md](CHANGELOG.md)、[docs/protocols.md](docs/protocols.md) 与
[docs/roadmap.md](docs/roadmap.md)。

## 许可

Hongda Core 采用独立实现，不含 GPL 上游代码。详见 [NOTICE.md](NOTICE.md)。
