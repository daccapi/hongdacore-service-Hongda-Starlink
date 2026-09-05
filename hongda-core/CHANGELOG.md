# Hongda Core Changelog

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
