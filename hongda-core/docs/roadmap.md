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
- Windows Wintun 设备、auto-route、strict-route 与退出路由清理（1.9.0-rc.1）
- gVisor TUN TCP/UDP 转发与 UDP 53 -> DoH 劫持（1.9.0-rc.1）

待完成：

1. 在无竞争 TUN 环境完成系统 HTTP、UDP、DoH 泄漏和异常退出实测
2. TCP DNS、FakeIP 与规则 DNS
3. 远程规则集下载、缓存、更新与规则集匹配
4. fallback / load-balance、进程匹配与更完整的路由动作
5. WireGuard / Tailscale
6. Hysteria2 / TUIC 与更多真实服务端互操作回归
