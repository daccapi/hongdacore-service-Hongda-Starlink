# Hongda Core 1.10.0 Windows TUN 验收记录

## 自动验证

- `go test ./...`
- `go test -tags with_gvisor ./...`
- `go vet -tags with_gvisor ./...`
- `HongdaService 1.5.0 doctor` 使用 Windows 当前配置通过。
- BanAD、LocalAreaNetwork、ChinaDomain、ChinaIp、ProxyLite 五个远程规则集已实际
  下载、严格解析并生成缓存。
- Flutter Windows 回归测试 8 项通过。
- 非 TUN VLESS 数据面实测通过：HTTP 与 SOCKS 入口均完成真实 HTTPS 请求，统计器
  记录上传 3696、下载 10843 字节。该次运行处于竞品代理在线环境，不替代下方的
  独立 HongdaTun 验收。
- HongdaService 1.5.0 已内嵌最新 HongdaCore 1.10.0；当前配置 `doctor` 返回
  `HONGDA_CHECK_OK`，嵌入 Core SHA-256 为
  `8b542b0b7593fa12dbdcc8d2fbe78cf78fd9e5f9f36d1a1c61c817d0e8c72726`。

## 管理员组合实测

实测前必须关闭其他代理软件的 TUN，避免两个默认路由接管器互相污染。测试
入口为 `TestLiveWindowsTUN`，覆盖：

1. 创建 HongdaTun、安装 split-default 与 strict-route。
2. 通过 VLESS 节点访问国外 HTTPS。
3. 命中 ChinaIp 后由绑定的物理网卡 DIRECT 访问国内 HTTPS，验证不回环。
4. UDP/53 与 TCP/53 原始 DNS 查询均转换为配置的 DoH detour。
5. 控制面实时上下行计数发生变化。
6. 退出时清理 HongdaTun 测试路由。

2026-08-14 在关闭其他代理软件 TUN、管理员 PowerShell 环境完成独立实测：

```text
=== RUN   TestLiveWindowsTUN
    live_integration_test.go:284: Windows TUN proxy/direct/DNS checks OK; up=79544 down=2741813
--- PASS: TestLiveWindowsTUN (17.47s)
PASS
ok      hongda.local/hongda-core/core   18.732s
```

结果确认 HongdaTun 在没有其它 TUN 帮助时可同时完成国外 VLESS 代理、国内物理网卡
DIRECT、系统 DNS 的 UDP/TCP 53 劫持以及实时流量计数。测试退出后 Core 正常清理
split-default 路由和 TUN 运行时。

## 仍需人工观察

- BrowserLeaks DNS 长时间结果以及浏览器自身 Secure DNS 的展示差异。
- 睡眠唤醒、Wi-Fi/网线切换、强制终止进程后的网络恢复。
- 不同运营商网络下的 IPv6（启用 IPv6 TUN 前，`ipv4_only` 会抑制 AAAA）。
