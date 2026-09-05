# Hongda Core Changelog

## 1.6.0

- 新增 Hysteria2 客户端：QUIC + HTTP/3 认证（`POST /auth`，`Hysteria-Auth` / `Hysteria-CC-RX` / `Hysteria-Padding`），TCP 流与 UDP datagram 中继。
- Hysteria2 TCP 使用 `0x401` 请求、标准响应校验；UDP 支持 datagram 分片重组与 QUIC varint 地址编码。
- 引入 MIT 许可的 `github.com/quic-go/quic-go`，不包含 sing-box / mihomo GPL 派生代码。
- `features` 新增 `hysteria2`。

## 1.5.0

- 新增 VLESS `xtls-rprx-vision` 流控的 TCP 兼容层：握手后使用 Vision padding 帧，读取端支持首帧 UUID、Continue/End/Direct 切换与原始流回退。
- 修正 VLESS Addons 编码，使用 protobuf 字段 `Flow=1` 的标准 wire 格式；修复服务端响应中非空 Addons 未被丢弃的问题。
- `features` 新增 `vless-vision`。

## 1.4.1

- 修复 direct 出站在启用 DoH 时可能发生的 DNS 泄漏：direct 连接前优先通过 DoH 解析域名并连接解析出的 IP，仅当出站为 direct 且 DoH 可用时生效。
- 保持 API 版本号与内核版本号同步。

## 1.4.0

- VLESS 支持 UDP over TCP（0x02，长度前缀帧）
- Trojan 支持 UDP over TCP（0x03，ATYP/addr/port/length 帧）
- 修复 VLESS TCP 未读取服务端 2 字节响应头的问题

## 1.3.0

- 新增 SOCKS5 UDP ASSOCIATE 入站（当前 direct 出站可用）
- 支持 UDP 中继、SOCKS5 UDP 头解析与回包封装

## 1.2.0

- 新增规则路由：domain / domain_suffix / domain_keyword / ip_cidr / network / port / reject
- 新增 DNS over HTTPS 解析（`dns.mode=doh`，用于 IP CIDR 规则判定）
- 修复 DoH 客户端避免走系统代理，防止代理环回

## 1.1.0

- 新增 REALITY（外借证书）客户端握手：
  - X25519 ECDH + HKDF-SHA256
  - AES-GCM SessionID 加密
  - ed25519 服务端证书 HMAC-SHA512 认证
- 新增 uTLS 指纹支持：
  - Chrome / Firefox / Safari / iOS / Edge / Android / Randomized
  - 支持指定具体版本指纹
- VLESS / Trojan 支持 WebSocket 传输层（客户端帧、掩码、握手校验）
- VLESS / Trojan 支持 gRPC-lite（V2Ray Gun）传输层
- 路由规则：域名后缀、关键词、IP CIDR、network、port、reject
- DNS over HTTPS 解析（供 IP CIDR 规则使用）
- 核心版本号升级为 `1.1.0`

## 1.0.0

- 独立干净室内核初始版本
- direct / VLESS TCP / Trojan TCP
- mixed 入站（SOCKS5 + HTTP CONNECT）
- select / urltest 策略组
- Clash 兼容控制面 `/version`、`/proxies`、`/connections`、`/traffic`
- sing-box JSON 导入器（仅格式兼容，不含 GPL 源码）
