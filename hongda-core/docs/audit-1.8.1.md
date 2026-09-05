# Hongda Core 1.8.1 审查报告

## 结论

1.8.0 不能直接替换 Windows 客户端中的生产 Core。它虽然在 `features` 中声明了
Reality、Vision、控制面 API 和流量统计，但真实链路存在多处会造成假连接、断流或
仪表盘无数据的缺陷；TUN、DNS 劫持和远程规则集也没有实现。

1.8.1 已把 mixed 系统代理模式的关键链路修到可做灰度测试，并改为对未实现配置
明确报错。开启 TUN 的生产配置仍会被拒绝，这是有意的安全行为，不是回归。

## 1.8.0 发现并已修复

- 外部格式导入器静默忽略 TUN、远程规则集和 DNS 语义，`check` 仍返回成功。
- REALITY ClientHello 的 AEAD 附加数据错误，真实服务端把连接转发到伪装站点。
- VLESS 在发送业务首包前等待响应，Vision/REALITY 会死锁。
- Vision 把一次 Go `Write` 当成协议结束，并且收到 `CommandDirect` 后没有退出外层
  TLS；代理转发稍有拆包就会 EOF、超时或间歇断开。
- HTTP CONNECT/SOCKS5 握手后的 bufio 预读数据被丢弃。
- SOCKS5 域名地址的 `ATYP` 被读取两次，域名目标无法连接。
- 所有 UDP ASSOCIATE 共用一个 UDP socket，存在抢读和一端断开导致全部中断。
- `/traffic` 是换行 HTTP 流而不是 Flutter 使用的 WebSocket。
- 流量在连接关闭后才累计，且上下行被重复/错误计数。
- `DELETE /connections` 只清空列表，不关闭实际连接，节点切换后旧流仍走旧节点。
- API 端口占用和后台监听失败可能被吞掉，Core 仍表现为 ready。
- 控制面 API secret 未校验；延迟接口只测 TCP connect，不是实际 URL 延迟。
- urltest 不定时刷新，策略组顺序变化会丢失成员。
- `features` 声明了 Core 本身没有提供的 IPC 和过于宽泛的 HTTP/Mux 能力。

## 已验证

- `go vet ./...` 通过。
- 全量 Go 单元测试通过。
- 打包后冒烟测试通过：`version`、`features`、`check`、HTTP 204、累计流量。
- 使用现有 VLESS + Reality + Vision 节点真实联网：HTTP CONNECT 与 SOCKS5 各
  连续 5 轮通过，累计字节每轮增长。
- 当前 Windows 生产配置会明确失败于 `TUN is not implemented`，不会再输出假成功。
- Go race 构建未执行：当前机器没有 race 模式所需的 GCC；这项仍应在 CI 补上。

## 尚未实现或未完成

| 优先级 | 能力 | 当前状态 | 影响 |
| --- | --- | --- | --- |
| P0 | Windows TUN + 路由 | 未实现 | ChatGPT、UWP、UDP/QUIC 等不保证接管 |
| P0 | DNS 劫持/FakeIP | 未实现 | TUN 下无法形成完整防泄漏闭环 |
| P0 | strict route/故障回滚 | 未实现 | 断线保护、路由恢复不可用 |
| P1 | 远程 `.srs` 规则集 | 未实现 | 国内/国外/广告规则配置不能导入 |
| P1 | 进程路由 | 未实现 | 无法按应用分流 |
| P1 | fallback/load-balance | 未实现 | 只能 select/urltest |
| P1 | Hysteria2/TUIC 互操作矩阵 | 只有单元测试 | 需要真实服务端、多 MTU、丢包环境验证 |
| P2 | WireGuard/Tailscale | 未实现 | 对应节点不能使用 |
| P2 | 完整 HTTP proxy | 仅 CONNECT | 明文 HTTP 正向代理请求不支持 |

DoH 已支持直接连接或经指定 selector/节点 detour，并支持独立 TLS server name；
但它不能代替 TUN 的端口 53 劫持、FakeIP 和系统 DNS 接管。

## 建议迭代顺序

1. 先实现 Windows TUN 设备、TCP/UDP 网络栈、默认路由和可靠回滚。
2. 同步实现端口 53 劫持、代理内 DoH、缓存与 DNS 泄漏回归测试。
3. 实现规则集下载/校验/缓存，再接入国内直连与国外代理策略。
4. 建立真实协议测试矩阵和 Windows CI race/长稳测试。
5. 完成以上 P0 后，再让 `HongdaService` 默认嵌入自研 Core；当前阶段只建议
   mixed 模式灰度，TUN 模式继续使用已验证的生产内核。
