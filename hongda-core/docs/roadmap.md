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
- Clash API
- VLESS Vision padding / Direct 切换
- VLESS XUDP
- Hysteria2 / TUIC
- Clash `/traffic` WebSocket 与实时连接统计
- 配置能力严格校验
- Windows Wintun 设备、auto-route、strict-route 与退出路由清理（1.9.0）
- gVisor TUN TCP/UDP 转发与 UDP 53 -> DoH 劫持（1.9.0，管理员实机验收通过）

待完成：

1. TCP DNS、FakeIP 与规则 DNS；补充 BrowserLeaks 长时间人工验收
2. 远程规则集下载、缓存、更新与规则集匹配
3. fallback / load-balance、进程匹配与更完整的路由动作
4. WireGuard / Tailscale
5. Hysteria2 / TUIC 与更多真实服务端互操作回归
