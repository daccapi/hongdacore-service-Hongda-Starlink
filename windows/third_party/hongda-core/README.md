# Hongda Core — 鸿达自研代理内核

Hongda Core 是鸿达星轨智连自己的协议、路由与控制面实现。

项目实现自有的命令行、外部格式配置导入和标准 HTTP/WebSocket 控制面。stdio
JSON IPC 由 `HongdaService` 提供，不属于 Core 本身。

Windows TUN 使用公开的 `sing-tun`、gVisor 与 Wintun 组件，并在
[NOTICE.md](NOTICE.md) 和二进制包 `licenses/` 中完整披露；这部分不伪装为原创。

## 架构

```text
cmd/hongda-core    命令行入口（version/features/check/run）
core/              运行时生命周期：Config -> Outbound/Group/Router/Inbound/API
model/             统一数据模型：Node/Outbound/Group/Rule/Config
protocol/          协议出站（direct / VLESS / Trojan / Hysteria2 / TUIC / Reality / uTLS / WS / gRPC）
strategy/          策略组（select / urltest）
route/             统一路由与流量统计
ruleset/           远程 source 规则集下载、缓存、校验与匹配
inbound/           入站（mixed：SOCKS5 + HTTP CONNECT）
tunnel/            Windows Wintun 生命周期、gVisor TCP/UDP、DoH 劫持与路由回滚
api/               标准控制面
telemetry/         流量与连接统计
config/            配置加载与格式识别
compat/singbox/     外部格式 JSON 导入器（仅格式转换）
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
- 控制面 API：`/version`、`/proxies`、`/proxies/{name}`、`/connections`、`/traffic`
- `/traffic` 使用标准 WebSocket；`/connections` 返回实时累计字节
- `/connection-log` 支持活动连接、关闭历史及游标增量读取
- 选择器切换后可通过 `DELETE /connections` 真正中断旧节点连接
- 规则路由：domain / domain_suffix / domain_keyword / ip_cidr / network / port / reject
- 远程规则集：把订阅 `.srs` 地址映射到同源 JSON，支持主源/备用源、严格校验、
  原子缓存、定时更新、失联时使用最后一份有效缓存与可选离线启动
- 首次规则集并行准备；DoH 复用长连接、合并相同并发问题并按 TTL 缓存响应，
  路由 IP 判定共享缓存，减少分流首连延迟
- DNS over HTTPS 解析（`dns.mode=doh`，用于 IP 规则判定，并在 direct 出站时预解析以避免本地 DNS 泄漏）
- 外部格式 JSON 导入器（供现有 Flutter UI 兼容）
- 流量/连接统计
- Windows Wintun + gVisor TUN（TCP/UDP、auto-route、strict-route）
- TUN UDP/TCP 53 劫持到配置的 DoH detour；没有加密 DNS 时拒绝 auto-route
- `ipv4_only` DNS 策略会返回空 AAAA 响应，防止只接管 IPv4 时从物理 IPv6 泄漏
- 域名 REJECT/广告规则在 DNS 劫持阶段直接返回 NXDOMAIN，避免 TUN 建连只剩 IP
  后丢失 BanAD 语义
- auto-route 启动前锁定物理默认网卡，DIRECT TCP/UDP socket 显式绑定该接口，
  物理网卡变化时同步更新，避免中国直连再次进入 HongdaTun
- 代理服务器端点路由排除和退出时精确路由清理

### 1.10.8 验证结果

- 非回环 Clash API 地址拒绝、IPv4/IPv6 前缀树匹配回归通过。
- 普通与 `with_gvisor` 全量测试、静态检查和 Windows 构建通过。

### 1.10.7 验证结果

- 连接日志初始快照、活动连接更新及关闭状态游标增量回归通过。
- 规则集主源失败后备用源接管、无缓存可选规则离线启动回归通过。
- 普通与 `with_gvisor` 全量测试、静态检查和 Windows 构建通过。

### 1.10.6 验证结果

- Flutter 原生 WebSocket 无 Origin 握手通过；非回环浏览器 Origin 继续拒绝。
- DoH transaction ID 缓存、连接复用、IPv4-only A-only 查询及普通/with_gvisor
  全量测试通过。
- Wintun 残留地址错误可识别并执行一次精确地址清理后重试。

### 1.10.5 验证结果

- 节点入口 TLS/WebSocket/gRPC 握手错误包含实际代理端点与失败阶段。
- `tls.insecure` 仅影响节点入口，目标网站 HTTPS 证书校验不受影响。

### 1.10.4 验证结果

- `/connections` HTTP/WebSocket、鉴权、首帧连接元数据、累计流量与关闭历史测试通过。
- `DELETE /connections` 仍立即确认请求并后台关闭真实 TCP/UDP socket。

### 1.10.0 验证结果

- 普通构建与 `with_gvisor` 全量测试、`go vet -tags with_gvisor ./...` 通过。
- Windows 当前五组订阅规则配置已通过 `HongdaService doctor`；BanAD、LAN、
  ChinaDomain、ChinaIp、ProxyLite 均成功下载并生成有效缓存。
- 新增规则 OR 语义、规则集域名/IP、缓存刷新/失联回退、TCP DNS、IPv4-only
  AAAA 抑制、控制面 WebSocket token 鉴权回归测试。
- 管理员 TUN 组合验收覆盖代理、物理直连、UDP/TCP DNS 和退出清理；实测结果记录
  在 `docs/tun-validation-1.10.0.md`。

### 1.9.0 验证结果

- `go vet -tags with_gvisor ./...` 与带 gVisor 标签的全量测试通过。
- Release 构建成功，Wintun DLL 已嵌入单文件 EXE，不依赖外置 DLL。
- 管理员实机测试通过：关闭竞争 TUN 后，系统 DNS 与无显式代理的 HTTPS 均通过
  Hongda TUN；测试记录为上行 5926、下行 18100 字节。
- 测试退出后未发现 HongdaTun 路由残留；竞争 TUN 检测仍会阻止双 TUN 启动。

### 1.8.1 验证结果

- `go vet ./...` 与全量单元测试通过。
- 使用现有 VLESS + Reality + Vision 节点进行真实联网回归：HTTP CONNECT 与
  SOCKS5 各连续 5 轮通过，目标为 `https://www.gstatic.com/generate_204`。
- `check` 现在会拒绝尚未实现的远程规则集等配置，不再静默
  丢弃后输出 `HONGDA_CHECK_OK`。

### 当前不能替换的功能

以下能力在 1.10.8 **尚未实现**，不能用功能声明或配置导入伪装为可用：

- FakeIP、进程路由、fallback / load-balance
- WireGuard / Tailscale

不支持的 `endpoints`、FakeIP 与进程规则会明确拒绝配置，不会静默丢弃后报告成功。

## 路线图

1. ~~Reality（外借证书）与 uTLS 指纹~~
2. ~~VLESS Vision 流控与 UDP/XUDP~~（Vision padding 与 XUDP 均已实现）
3. ~~WebSocket / gRPC 传输~~（WebSocket 与 gRPC-lite 已实现，仍需服务端对等验证）
4. ~~Hysteria2 / TUIC（QUIC）~~（Hysteria2 与 TUIC 均已实现）
5. ~~Windows TUN 网卡接管、自动路由与 strict route~~（1.9.0 实机验收通过）
6. ~~UDP/TCP DNS 劫持到 DoH~~；继续完成 FakeIP 与规则 DNS
7. ~~远程规则集下载、缓存与匹配~~；继续完成高级路由
8. WireGuard / Tailscale

详见 [CHANGELOG.md](CHANGELOG.md)、[docs/protocols.md](docs/protocols.md) 与
[docs/roadmap.md](docs/roadmap.md)。

## 许可

Hongda 协议与控制面为本项目实现；Windows TUN 链接 GPL/Apache/Wintun 第三方
组件并保留许可。详见 [NOTICE.md](NOTICE.md)。
