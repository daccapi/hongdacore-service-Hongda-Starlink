# Hongda Core 1.9.0 Windows TUN 验收记录

## 环境与边界

- Windows x64，管理员 PowerShell。
- Go 1.25.0，构建标签 `with_gvisor`。
- 使用现有 VLESS + Reality + Vision 节点。
- 验收前禁用其他代理软件的 TUN 默认路由，避免双 TUN 污染结果。
- 测试不读取或输出节点密钥，仅从现有配置内存导入一个具体节点。

## 自动验收

执行：

```powershell
$env:HONGDA_LIVE_TUN = "1"
$env:HONGDA_LIVE_CONFIG = "$env:APPDATA\HongdaStarlink\runtime\config.json"
go test -tags with_gvisor ./core -run '^TestLiveWindowsTUN$' -v -count=1 -timeout 2m
```

结果：

```text
=== RUN   TestLiveWindowsTUN
    live_integration_test.go:236: Windows TUN request OK; up=5926 down=18100
--- PASS: TestLiveWindowsTUN (3.29s)
PASS
ok   hongda.local/hongda-core/core 4.482s
```

覆盖的真实链路：

1. 创建并配置 `HongdaTun` Wintun 设备。
2. 安装 IPv4 分流默认路由与 strict-route/WFP 规则。
3. Windows 系统 DNS 查询进入 TUN，UDP 53 原始报文经选中节点转发至 DoH。
4. 未设置 HTTP/SOCKS 代理的 HTTPS 请求通过 gVisor TCP 和 Hongda Router。
5. 上下行实时计数发生变化。
6. 测试结束关闭 TUN，并确认系统未残留 Hongda 路由。

## 尚未覆盖

- TCP 53 DNS 回退、FakeIP 和规则 DNS。
- 远程 `.srs` 规则集下载与匹配。
- 浏览器长时间运行、休眠唤醒、物理网络切换和强制杀进程恢复。
- WireGuard / Tailscale 出站。

在上述功能完成前，1.9.0 应使用全局代理、私网直连的兼容配置进行客户端灰度，
不能把远程规则集静默忽略后当作原配置等价执行。
