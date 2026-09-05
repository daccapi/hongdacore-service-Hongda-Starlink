# Hongda Core Changelog

## 1.9.0-rc.1

- 新增 Windows Wintun 入站：导入 sing-box `tun` 配置，支持 IPv4 地址、MTU、
  `auto_route`、`strict_route`、接口名和 `route_address`。
- 接入 gVisor 用户态 TCP/IP 栈；TUN TCP/UDP 会话进入 Hongda Router，再由当前
  selector/VLESS 等出站转发，不再只是创建一张没有数据面的虚拟网卡。
- TUN UDP 支持多目标 NAT 会话；TCP/UDP 都计入 Clash `/traffic` 与连接统计，
  `DELETE /connections` 可关闭旧节点的 TUN 会话。
- 实现端口 53 UDP 劫持，把原始 DNS wire message 通过配置的 DoH detour 发送，
  并保留 DNS transaction ID；无加密 DNS 时拒绝开启 auto-route TUN。
- 启动前解析并排除代理服务器端点，避免内核自身连接重新进入 TUN；退出时按接口
  和精确前缀删除已安装路由，再关闭 WFP/session/adapter。
- 新增有超时与强制回滚的 Windows TUN 实机测试；检测到 Karing/Clash 等竞争
  TUN 时主动跳过，防止双 TUN 破坏系统网络。
- Windows 构建固定使用 `with_gvisor` 标签，版本升级为 `1.9.0-rc.1`。
- 该 RC 已通过构建、vet 和单元测试；由于测试机当前仍运行 Karing TUN，尚未完成
  无竞争代理条件下的系统 HTTP/DNS 实测，不能替换正式内核。

## 1.8.1

- 修复 REALITY ClientHello：AEAD 附加数据改为使用清零 SessionID 的原始
  ClientHello，服务端不再把认证失败的连接转发到伪装站点。
- 修复 VLESS 在 `DialContext` 中提前等待响应头造成的 Vision/REALITY 首包死锁；
  响应头改为首次读取时延迟消费。
- 修复 Vision 把一次 Go `Write` 错当成协议边界的问题；按完整 TLS record 聚合，
  并在 ApplicationData 后结束 padding。
- 正确处理 Vision `CommandDirect`：切换到外层 TLS 的底层连接；增加 TLS record
  边界包装，防止 uTLS 预读造成原始数据丢失。
- 修复 HTTP CONNECT/SOCKS5 握手后 bufio 预读数据丢失，以及 SOCKS5 `ATYP`
  被读取两次导致域名地址失败的问题。
- SOCKS5 UDP ASSOCIATE 改为每个控制连接独立 UDP socket，避免多个客户端抢读
  或任一客户端断开后关闭全局 UDP 端口。
- `/traffic` 改为 Clash 兼容 WebSocket；实时字节在转发过程中累计，不再等连接
  关闭，并修复上下行重复/方向错误统计。
- `DELETE /connections` 现在关闭真实 socket，确保运行中切换节点不会保留旧连接。
- API 监听改为同步绑定，端口占用会立即失败；实现 Clash API Bearer 密钥校验。
- 延迟测试改为通过目标出站完成 HTTP/HTTPS 请求，并支持调用方 `timeout`。
- urltest 按配置周期刷新；策略组支持前向引用并检测循环/未解析依赖。
- sing-box 配置导入改为严格校验。TUN、DNS 劫持、远程规则集等
  未实现能力会明确失败，不再静默忽略后报告成功。
- DoH 支持按配置经 selector/节点 detour 建立连接，并保留独立 TLS server name，
  避免 DoH 端点为 IP 时证书名称错误。
- 修正 `features`，移除 Core 本身并不存在的 `ipc` 和笼统 `mux/http` 声明。
- 版本升级为 1.8.1。

## 1.8.0

- 新增 VLESS XUDP（Mux.Cool 单连接 UDP）出站，用于 `packet_encoding: xudp`。
- XUDP 首包使用 `New` 帧（目标地址 + 8 字节 GlobalID），后续使用 `Keep` 帧，关闭时发送 `End` 帧。
- VLESS UDP 默认切换为 XUDP（与 sing-box 默认一致），`packet_encoding: packetaddr` 保留原长度前缀帧回退。
- `features` 新增 `vless-xudp` 与 `mux`。
- 未引入 GPL 代码，XUDP 按公开 wire format 独立实现。

## 1.7.0

- 新增 TUIC v5 客户端：QUIC + TLS Keying Material Exporter 认证，TCP Connect、UDP Packet 分片与关联会话。
- TUIC 地址编码支持域名 / IPv4 / IPv6 / None；`features` 新增 `tuic`。
- 继续使用 MIT 许可的 `github.com/quic-go/quic-go`，未引入 GPL 代码。

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
