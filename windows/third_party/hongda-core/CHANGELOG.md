# Hongda Core Changelog

## 1.10.6

- DoH 改为复用 HTTP/2/HTTP/1.1 长连接，不再为每个域名重新建立
  VLESS/WebSocket/TLS/DoH 全链路；相同并发查询合并，响应按 TTL 缓存并恢复各自的
  DNS transaction ID。
- `ipv4_only` 的内部 IP 判定只查询 A 记录，不再额外串行请求 AAAA。
- `/traffic` 与 `/connections` WebSocket 接受不带 `Origin` 的 Flutter 原生客户端；
  浏览器来源仍限制为回环地址，修复 403 与 HTTP 轮询降级。
- Wintun 遇到上次异常退出残留地址时，仅清理 HongdaTun 的精确 IPv4/IPv6 地址并
  重试一次，修复 `The object already exists` 启动失败。
- 版本升级为 `1.10.6`。

## 1.10.5

- 代理入口 TLS、WebSocket 与 gRPC 握手错误新增实际代理端点和失败阶段，避免把
  节点入口证书过期误报成测速目标网站证书异常。
- 保持 `tls.insecure` 为显式选择：开启时只跳过代理入口证书验证，穿过代理后的
  HTTPS 仍由客户端正常验证目标网站证书。
- 版本升级为 `1.10.5`。

## 1.10.4

- `/connections` 同时支持 HTTP 与 WebSocket；WebSocket 首帧立即返回，之后每秒推送
  活动连接、每连接计数和累计上下行。
- 连接关闭时间改用读写锁保护，消除网络线程删除连接与 API 序列化之间的数据竞争。
- 新增连接流 API、元数据与累计流量回归测试；原 HTTP/DELETE 语义保持不变。
- 功能集新增 `connection-stream`，版本升级为 `1.10.4`。

## 1.10.3

- 连接遥测增加来源、域名、原始目标、逻辑路由、实际出站、命中规则、开始与关闭时间。
- 新增 `/connection-log` API，返回活动连接和最近 1000 条关闭连接；支持清除关闭历史。
- `/connections` 保持活动连接专用，不改变 Flutter 实时流量和节点切换清理语义。
- 混合代理与 Windows TUN 均记录实际目标；选择器记录建连时真正使用的节点。
- 新增 API 元数据、关闭历史、规则说明以及真实 VLESS 连接日志测试。
- 版本升级为 `1.10.3`。

## 1.10.2

- DNS 劫持响应增加按 TTL 管理的域名/IP 双向关联，TUN 后续只携带 IP 的连接仍可
  匹配 domain、domain_suffix、domain_keyword 与远程规则集。
- TCP/443 增加无损 TLS ClientHello SNI 识别，覆盖应用内 DoH/加密 DNS；缓冲数据
  会完整回放，出站仍拨号到原始目标 IP。
- 新增 YouTube A 记录、Google AAAA、SNI 与 UDP/443 拒绝回归测试。
- 版本升级为 `1.10.2`。

## 1.10.1

- `DELETE /connections` 改为立即返回、后台关闭已登记的 TCP/UDP 真实 socket，
  避免 TUN UDP 包循环退出较慢时控制面 API 阻塞，导致 Flutter 节点切换超时。
- 新增慢 socket close 回归测试，确保 API 在 500 ms 客户端时限内返回，
  同时后台关闭任务确实启动。
- 版本升级为 `1.10.1`。

## 1.10.0

- 支持 Windows 客户端现用的五组订阅远程规则集；binary `.srs` URL 会读取
  同源 source JSON，严格校验支持字段后原子缓存，按 `update_interval` 更新，网络
  失败时仅回退到最后一份已验证缓存。
- 修正规则匹配语义：domain / suffix / keyword / IP CIDR / rule-set 在目标地址组内
  按 OR 匹配，network / port 继续按 AND 限制。
- auto-route TUN 启动前获取真实默认网卡，DIRECT TCP/UDP socket 显式绑定物理
  interface index，并跟随默认网卡更新，允许 China/LAN 直连而不重新进入 TUN。
- 新增 TCP/53 DNS stream 劫持；与 UDP/53 一样保留 transaction ID 并经配置的
  DoH detour 转发。
- 导入并执行 DNS `strategy`；`ipv4_only` 对 AAAA 返回空响应，避免未接管 IPv6
  时发生 DNS/出口泄漏。
- 域名/规则集 REJECT 会在 DNS 劫持阶段返回 NXDOMAIN，不向上游解析器发送广告
  域名，并解决 TUN 后续只看到目标 IP 时 BanAD 无法生效的问题。
- `/traffic?token=...` 支持 query token 鉴权，修复启用 API secret 后 Flutter
  实时流量 WebSocket 无法连接。
- `check`/`doctor` 会实际准备远程规则集；下载或首次校验失败发生在安装 TUN 路由
  之前，避免半启动状态。
- 五组规则集并行准备；路由中的重复域名 IP 判定共享一分钟 DoH 缓存，避免同一
  首连为 LAN/CN、ProxyLite、ChinaIp 连续发起多轮 A/AAAA 查询。
- 空缓存首次下载限制为两路并发，并对超时、429、5xx 增加一次有限重试，避免
  VLESS 节点或 CDN 短暂变慢时导致首次启动失败。
- 明确拒绝尚未实现的 endpoint（包括 Tailscale），不再静默忽略。
- 关闭竞品代理后的独立管理员实测通过：国外代理、国内 DIRECT、UDP/TCP DNS
  劫持和流量统计全部成功（上传 79544、下载 2741813 字节）。
- 版本升级为 `1.10.0`。

## 1.9.0

- 新增 Windows Wintun 入站：导入标准 `tun` 配置，支持 IPv4 地址、MTU、
  `auto_route`、`strict_route`、接口名和 `route_address`。
- 接入 gVisor 用户态 TCP/IP 栈；TUN TCP/UDP 会话进入 Hongda Router，再由当前
  selector/VLESS 等出站转发，不再只是创建一张没有数据面的虚拟网卡。
- TUN UDP 支持多目标 NAT 会话；TCP/UDP 都计入 `/traffic` 与连接统计，
  `DELETE /connections` 可关闭旧节点的 TUN 会话。
- 实现端口 53 UDP 劫持，把原始 DNS wire message 通过配置的 DoH detour 发送，
  并保留 DNS transaction ID；无加密 DNS 时拒绝开启 auto-route TUN。
- 启动前解析并排除代理服务器端点，避免内核自身连接重新进入 TUN；退出时按接口
  和精确前缀删除已安装路由，再关闭 WFP/session/adapter。
- 新增有超时与强制回滚的 Windows TUN 实机测试；检测到其他代理软件的竞争
  TUN 时主动跳过，防止双 TUN 破坏系统网络。
- Windows 构建固定使用 `with_gvisor` 标签，版本升级为 `1.9.0`。
- 管理员实机验收通过：关闭竞争 TUN 后，系统 DNS 和无显式代理的 HTTPS 均通过
  Hongda TUN；单次测试上行 5926、下行 18100 字节，退出后未残留 Hongda 路由。

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
- `/traffic` 改为标准兼容 WebSocket；实时字节在转发过程中累计，不再等连接
  关闭，并修复上下行重复/方向错误统计。
- `DELETE /connections` 现在关闭真实 socket，确保运行中切换节点不会保留旧连接。
- API 监听改为同步绑定，端口占用会立即失败；实现控制面 API Bearer 密钥校验。
- 延迟测试改为通过目标出站完成 HTTP/HTTPS 请求，并支持调用方 `timeout`。
- urltest 按配置周期刷新；策略组支持前向引用并检测循环/未解析依赖。
- 外部格式配置导入改为严格校验。TUN、DNS 劫持、远程规则集等
  未实现能力会明确失败，不再静默忽略后报告成功。
- DoH 支持按配置经 selector/节点 detour 建立连接，并保留独立 TLS server name，
  避免 DoH 端点为 IP 时证书名称错误。
- 修正 `features`，移除 Core 本身并不存在的 `ipc` 和笼统 `mux/http` 声明。
- 版本升级为 1.8.1。

## 1.8.0

- 新增 VLESS XUDP（Mux.Cool 单连接 UDP）出站，用于 `packet_encoding: xudp`。
- XUDP 首包使用 `New` 帧（目标地址 + 8 字节 GlobalID），后续使用 `Keep` 帧，关闭时发送 `End` 帧。
- VLESS UDP 默认切换为 XUDP（与上游生态默认一致），`packet_encoding: packetaddr` 保留原长度前缀帧回退。
- `features` 新增 `vless-xudp` 与 `mux`。
- XUDP 按公开 wire format 独立实现。

## 1.7.0

- 新增 TUIC v5 客户端：QUIC + TLS Keying Material Exporter 认证，TCP Connect、UDP Packet 分片与关联会话。
- TUIC 地址编码支持域名 / IPv4 / IPv6 / None；`features` 新增 `tuic`。
- 继续使用 MIT 许可的 quic-go 库。

## 1.6.0

- 新增 Hysteria2 客户端：QUIC + HTTP/3 认证（`POST /auth`，`Hysteria-Auth` / `Hysteria-CC-RX` / `Hysteria-Padding`），TCP 流与 UDP datagram 中继。
- Hysteria2 TCP 使用 `0x401` 请求、标准响应校验；UDP 支持 datagram 分片重组与 QUIC varint 地址编码。
- 引入 MIT 许可的 quic-go 库。
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
- 标准兼容控制面 `/version`、`/proxies`、`/connections`、`/traffic`
- 外部格式 JSON 导入器
