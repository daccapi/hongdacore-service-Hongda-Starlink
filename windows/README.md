# 鸿达星轨智连 V1.6.13 — Windows 源码

鸿达星轨智连 Windows 客户端，采用 Flutter 桌面 UI、独立 `HongdaService.exe` 监管进程和本地源码构建的 `HongdaCore.exe`。应用版本为 **1.6.13+173**，Service 版本为 **1.5.2**，核心版本为 **1.10.2**。

## 运行架构

```text
Hongda Starlink.exe
  └─ HongdaService.exe 1.5.2
       └─ HongdaCore.exe 1.10.2
            ├─ VLESS / Reality / Trojan / Hysteria2 / TUIC
            ├─ Wintun / gVisor / DoH / 规则集 / Selector / URLTest
            └─ Clash API: 127.0.0.1:<运行时 API 端口>
```

Flutter 负责节点、订阅、配置生成、启动编排、stdio JSONL IPC、Clash API 和 Windows 系统代理。`HongdaService.exe` 负责释放并启动 `HongdaCore.exe`，将其加入 kill-on-close Windows Job Object，避免 Service 异常退出后遗留核心进程。

`HongdaCore.exe` 由 `tools/build-core.ps1` 从相邻 `hongda-core` 源码构建，随后作为资源嵌入 `HongdaService.exe`。Core 不导入 sing-box 运行时代码；Windows TUN 使用并保留 sing-tun、gVisor、Wintun 的第三方许可与声明。

## V1.6.13 主要变化

- 修复 TUN 建连阶段只有 IP、导致 Google/YouTube 域名规则失效的问题：Core 现在
  按 DNS TTL 保存域名与响应 IP 的关联，并在真实连接上重新匹配域名规则集。
- TCP/443 增加无损 SNI 识别，浏览器使用加密 DNS 时仍能识别 YouTube/Google，
  同时保持实际目标 IP 不变。
- YouTube、Google Video、Google API/静态资源关键域名内置高优先级代理规则，
  即使远程列表缺项也不会落到 `final=direct`。
- 默认启用 IPv4-only 防泄漏配置；TUN 仍接管 IPv6，但在核心内明确拒绝并快速
  回退 IPv4，避免 Google 从物理网卡显示 IPv6。
- TUN 拒绝 UDP/443 以关闭不稳定 QUIC，使 YouTube 经 VLESS 的 TCP/TLS 路径连接。
- Service/Core 分别升级到 1.5.2/1.10.2，并补充 DNS 关联、SNI、IPv6 和 QUIC 回归测试。

## V1.6.12 主要变化

- 删除会因 jsDelivr 边缘缓存返回 404 而阻止启动的独立 `OpenAi.srs` 下载。
- OpenAI、ChatGPT、静态资源和内容域名改为配置内置高优先级规则；同时继续由
  ProxyLite 与 ProxyGFWlist 提供完整海外站点覆盖。
- Doctor 不再因一个重复的小型规则集下载失败而拒绝整个 TUN 配置。

## V1.6.11 主要变化

- 修复退出后错误恢复失效的 `localhost` 系统代理：恢复前检查本地 TCP 端口，
  Karing 等代理进程已经退出时不再重新启用其旧端口。
- 系统代理恢复同时保护 `ProxyEnable`、服务器和绕过列表；用户在运行期间手动修改
  代理时保留用户的新状态，崩溃恢复与正常退出使用同一套校验。
- 智能分流改为 Karing 式选择性代理：OpenAI、ProxyLite、ProxyGFWlist 命中走节点，
  中国域名/IP 直连，规则未命中的普通国外站点最终直连。
- IPv6 开启时增加 ChinaIpV6 直连规则；OpenAI 规则在中国 IP 判断前执行，避免
  ChatGPT 因共享 CDN 地址或污染解析被误判为直连。
- 版本号和窗口标题统一升级到 V1.6.11，发布脚本直接输出迭代后的运行包与源码包。

## V1.6.10 主要变化

- 修复 HongdaCore 为代理服务器保留物理网卡 `/32` 绕行路由后，Windows 将两条 `/1`
  拆分为更细前缀，客户端误报“缺少 IPv4 默认/split 路由”并主动断开的问题。
- TUN 就绪检查改为分别验证 IPv4 低半区与高半区的 Windows 实际最优路由，
  既允许节点端点绕行，又会拒绝只接管一半 IPv4 流量的不完整 TUN。
- 新增“端点绕行分段路由”与“仅接管半区”回归用例。
- 侧边栏软件名独占首行，版本徽标缩小并移到副标题行。
- 连接、断开和节点切换增加单飞保护，阻止重复 Service 和 Wintun 创建。
- Core 1.10.1 将旧连接清理改为后台执行，API 立即确认，节点切换不再等待 6 秒超时。

## V1.6.9 主要变化

- Windows 运行核心切换到 HongdaCore 1.10.0，Service 升级到 1.5.0。
- 当前五组 Karing 规则可由 Core 下载同源 JSON、严格校验、缓存、更新并匹配。
- 空缓存首次下载限制为两路并发，并对超时、429、5xx 做一次有限重试；缓存验证后
  启动不再依赖 CDN 即时响应。
- China/LAN DIRECT socket 绑定物理默认网卡，修复 auto-route 下直连回到 HongdaTun。
- UDP/TCP 53 都劫持到代理 DoH；`ipv4_only` 抑制 AAAA，降低 DNS/IPv6 泄漏。
- API Secret 下 `/traffic?token=` 可正常连接，修复实时流量图没有数据。
- 保留动态 Mixed/API 端口和运行时节点 PUT/GET/URLTest/关闭旧连接验证。
- `doctor` 现在拒绝未实现的协议、HTTP transport、Hysteria2 obfs、TUIC 非
  cubic 拥塞控制和 multiplex，不再把被忽略的关键参数报告为可用。
- 删除不再使用的 Cronet 二进制，Service 从旧版约 55 MB 降至约 17 MB。
- 尚未实现的 Tailscale 设置明确禁用并迁移旧开关，不再伪装为已生效。
- 已在关闭 Karing 后通过独立管理员 HongdaTun 实测：国外代理、国内 DIRECT、
  UDP/TCP DNS 劫持和流量统计全部通过。

## V1.6.8 主要变化

- 修复仪表盘“实时流量”曲线始终为空：采样历史改为滑动赋值，并修复迷你曲线因原地修改列表而不重绘的问题。
- Clash `/traffic` WebSocket 鉴权改用 `?token=` 查询参数，设置 API Secret 后流量监控仍可用。
- 国家/地区识别不再把 `free`、`this`、`phone`、`running` 等英文单词误判为国家码。
- Shadowsocks SIP002 密码自动 base64 解码，兼容明文密码。
- 修复 DNS 泄露与被墙站点分流失败：DNS 默认改为 DoH 且经代理，路由顺序调整为“中国域名直连 → 代理列表 → 中国 IP 直连”。
- fakeip DNS 补充上游 `server`；关闭 TUN 后自动恢复系统代理。
- 原生系统代理恢复增加“用户手动改过则不覆盖”保护；控制器销毁时主动清理残留核心进程。
- 发布脚本自动打包 MSVC 运行库，避免干净机器缺少 VC++ 运行时无法启动。

## V1.6.7 主要变化

- 修复 TUN 与 Windows 本机系统代理同时启用时，浏览器正常但 ChatGPT 等 AppContainer/WebView 应用无法联网的问题；TUN 连接期间会临时暂停现有系统代理，断开或异常恢复后原样还原。
- Windows TUN 默认启用严格路由与 IPv4/IPv6 双栈 split routes，减少 DNS/IPv6 绕行。
- “已连接”前除检查 HongdaTun 网卡和路由外，还会验证 Windows 最优路由及真实 HTTPS 联网；仅有虚拟网卡不再判定成功。
- 运行中切换节点改为严格轮询 selector、清理旧 HTTP/2/WebSocket/QUIC 连接、通过 `proxy` selector 做 URLTest，并在失败时回滚。

## V1.6.6 主要变化

- 国家识别支持 `jpda`、`hk01` 等国家码与线路后缀连写；节点页可手动设置国家/地区。
- 新增服务器 IP 地区检测。仅在用户点击并确认后把服务器 IP 发给 `ipwho.is`，不发送节点凭据；结果缓存在 `nodes.json`。
- 修复“TCP 端口可达”被保存为错误并显示红叉：状态区分当前连接、代理可用、TCP 可达、失败和未测试。
- 实时流量改用 Clash `/connections` 顶层 `uploadTotal/downloadTotal` 计算，短连接在轮询前关闭也不会丢失；WebSocket 同时兼容文本与二进制帧。
- Windows TUN 默认迁移到 mixed 栈、MTU 1500、IPv4 与非严格路由，并使用两条 `/1` split route 接管系统流量。
- 新增原生 HongdaTun 网卡/路由检查；未真正建立系统路由时不再显示“已连接”。

## V1.6.5 主要变化

- 国家/地区显示不再依赖 Windows 旗帜 Emoji 字体，改用 Flutter 绘制的国家徽标，并支持按国家搜索。
- 仪表盘增加紧凑与超紧凑布局；普通 1366×768 级窗口保持左右网格并压缩次要内容，不再必须最大化才能看到主要模块。
- 实时流量不区分手动节点和订阅节点。优先使用 Clash `/traffic`，不可用或持续为零时从 `/connections` 的真实累计字节计算速率。
- Mixed/API 端口由固定值改为“首选端口”。端口占用时自动选择相邻可用端口，并同步到配置、API、WebSocket、系统代理和界面。
- 订阅更新保留节点稳定 ID、收藏、启用状态、延迟和错误记录，避免刷新后选中节点丢失。
- WebSocket 重连增加代次与单定时器控制，避免断线后产生重复连接。
- Windows 核心从预编译 `sing-box.exe` 资源切换为本地源码构建的 `HongdaCore.exe`；旧重复资源已清理。

完整记录见 [CHANGELOG.md](CHANGELOG.md)。

## 构建环境

```text
Windows 10/11 x64
Flutter 3.44.4 / Dart 3.12.2
Visual Studio 2022 Build Tools（Desktop development with C++）
Go 1.25.0
```

构建完整 Windows 发布包：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

仅构建核心和 Service：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-core.ps1
powershell -ExecutionPolicy Bypass -File .\tools\build-service.ps1 -SkipCoreBuild
```

生成不含 EXE/DLL/Flutter 缓存、但内含完整 HongdaCore 源码和第三方许可的源码包：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\package-source.ps1
```

默认运行包输出到项目上级目录：`Hongda-Starlink-V1.6.13-Windows-x64.zip`。详细步骤见 [BUILD_WINDOWS.md](BUILD_WINDOWS.md)。

## 本地数据

```text
%APPDATA%\HongdaStarlink\settings.json
%APPDATA%\HongdaStarlink\nodes.json
%APPDATA%\HongdaStarlink\subscriptions.json
%APPDATA%\HongdaStarlink\groups.json
%APPDATA%\HongdaStarlink\rules.json
%APPDATA%\HongdaStarlink\traffic.json
%APPDATA%\HongdaStarlink\runtime\config.json
```

`7890` 和 `9090` 只是默认首选值。若发生占用，实际端口会自动保存到 `settings.json`，界面状态栏与系统代理均使用实际值。

HongdaCore 1.10 当前支持 VLESS、Trojan、Hysteria2、TUIC。订阅中其它协议不会
阻止已支持节点启动，但不会进入运行配置；直接选择未支持协议会显示明确错误。
VLESS/Trojan 当前支持 raw、WebSocket 与 gRPC transport；带有尚未实现参数的节点
会在启动前由 `doctor` 明确拒绝，不会显示虚假的“已连接”。

## 目录说明

```text
lib/                    Flutter UI、节点/订阅/配置和控制逻辑
service/                HongdaService Go 源码与嵌入资源
service/embedded/       HongdaCore.exe
runtime/service/        发布时携带的 HongdaService 与第三方声明
tools/                  核心、Service、Windows 发布构建脚本
windows/                Flutter Windows Runner 与原生集成
third_party/hongda-core/ 可选的本地 HongdaCore 源码位置
```

## 第三方说明

Hongda 品牌覆盖应用自身的 UI、服务封装、构建链和协议/路由控制面实现。Windows TUN 仍链接 sing-tun、gVisor 并嵌入 Wintun；发布包必须保留 `NOTICE.md` 与适用的许可证。仅内部自用不等于第三方版权归属消失。
