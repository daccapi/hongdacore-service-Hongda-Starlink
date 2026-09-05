# 路线图

已完成：

- direct
- VLESS TCP + TLS
- Trojan TCP + TLS
- REALITY + uTLS
- WebSocket
- gRPC-lite
- VLESS / Trojan UDP over TCP
- mixed 入站
- SOCKS5 UDP ASSOCIATE（direct UDP 中继）
- select / urltest
- 控制面 API
- VLESS Vision padding / Direct 切换
- VLESS XUDP
- Hysteria2 / TUIC
- `/traffic` WebSocket 与实时连接统计
- 配置能力严格校验
- Windows Wintun 设备、auto-route、strict-route 与退出路由清理（1.9.0）
- gVisor TUN TCP/UDP 转发与 UDP/TCP 53 -> DoH 劫持
- 远程规则集下载、严格校验、原子缓存、更新、失联回退与匹配（1.10.0）
- Windows DIRECT 绑定物理默认网卡，避免 auto-route 回环（1.10.0）
- `ipv4_only` 抑制 AAAA，避免 IPv4-only TUN 的物理 IPv6 泄漏（1.10.0）

待完成：

1. FakeIP 与更完整的规则 DNS；补充 BrowserLeaks 长时间人工验收
2. fallback / load-balance、进程匹配与更完整的路由动作
3. WireGuard / Tailscale
4. Hysteria2 / TUIC 与更多真实服务端互操作回归
