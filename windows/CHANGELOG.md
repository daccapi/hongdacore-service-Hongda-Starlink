# 更新记录

## V1.6.24 — 2026-08-29

### Hysteria2 Salamander 与配置隔离

- HongdaCore 实现 Hysteria2 Salamander UDP 数据包混淆，支持订阅配置中的
  `obfs.type=salamander` 与独立混淆密码。
- Flutter 配置生成器不再只按协议名称判断兼容性；现在同时检查 transport、multiplex、
  Hysteria2 obfs 与 TUIC 参数。
- 未选中的不兼容节点会从本次运行配置中安全跳过并记录节点名及原因，不再出现一个
  Hysteria2 节点使当前 VLESS 连接无法通过 Doctor 的连锁故障。
- 主动选择不兼容节点时直接给出具体错误，不再只显示泛化的“协议不支持”。
- 新增 Salamander 数据包往返、盐/密码密钥隔离、配置导入及 Flutter 配置过滤回归测试。
- 版本：鸿达星轨智连 `1.6.24+184`，HongdaService `1.5.11`，HongdaCore `1.10.11`。

## V1.6.23 — 2026-08-29

### 延迟指标修复

- 修复将完整代理 URLTest 总耗时误标为节点延迟的问题；列表与仪表盘改为显示节点
  TCP RTT 的三次采样中位数。
- 完整代理验证继续保留，只有目标站请求成功才标记节点“代理可用”；节点状态与日志
  同时展示节点 RTT、代理传输建立耗时和完整代理链路耗时。
- Clash 兼容字段 `delay` 保持完整 URLTest 语义；Core 新增 `connectDelay`、
  `totalDelay` 字段，避免外部兼容性回归。
- 延迟探针改用 HEAD 且禁止自动跟随重定向，避免把下载内容或重定向链计入测速。
- 版本：鸿达星轨智连 `1.6.23+183`，HongdaService `1.5.10`，HongdaCore `1.10.10`。

## V1.6.22 — 2026-08-28

### DPAPI 本地数据保护

- `settings.json`、`nodes.json`、`subscriptions.json` 及 `.bak/.tmp` 改为
  Windows 当前用户 DPAPI 密文，节点 UUID/密码、订阅 Token 和 API Secret 不再明文落盘。
- 首次读取旧格式时自动原地迁移；DPAPI 暂不可用时仍优先保证旧数据可读，后续保存重试。
- 运行期 `config.json` 继续只在连接期间存在并在退出路径清理。

### DNS 重启性能与 URLTest 稳定性

- HongdaCore 在 `runtime/rulesets/dns-cache-v1.dat` 保存仍在 TTL 内的 DoH 响应；
  Windows 文件使用独立 DPAPI entropy 加密，损坏、过期或其它用户缓存安全忽略。
- DNS 缓存每五秒低频落盘并在 Core 正常关闭时刷新，不为每个查询同步写磁盘。
- URLTest 应用 `tolerance` 滞回：健康当前节点不会因小幅延迟抖动被切换；当前失败时
  立即选择可用的最佳成员。
- 版本：鸿达星轨智连 `1.6.22+182`，HongdaService `1.5.9`，HongdaCore `1.10.9`。

## V1.6.21 — 2026-08-28

### 运行可靠性与安全边界

- 新增运行中 TUN 巡检：每 30 秒检查 HongdaTun 网卡、split route 与 Windows 最优
  路由，连续两次失败才显示异常；每五分钟执行严格 HTTPS 探针，恢复后自动更新状态。
- 正常断开、启动失败、Core 异常退出和应用销毁时清理运行期
  `config.json/.bak/.tmp`，缩短节点临时凭据在磁盘上的保留时间。
- `client.log` 达到 10MB 自动轮转，保留三份历史，避免长期运行无限占用磁盘。
- HTTPS 订阅拒绝降级重定向到 HTTP；纯 HTTP 订阅必须由用户显式开启不安全选项。
- Core 配置校验强制 Clash API 绑定回环地址，拒绝 `0.0.0.0`、`::` 和局域网地址。

### 规则性能与配置一致性

- 规则集 IP CIDR 从线性扫描改为 IPv4/IPv6 前缀树，匹配开销限制在地址位宽内。
- 删除当前 HongdaCore 未实现的 `experimental.cache_file` 配置，避免产生虚假的 DNS
  持久化缓存声明；现有 DoH TTL 内存缓存保持不变。
- 版本：鸿达星轨智连 `1.6.21+181`，HongdaService `1.5.8`，HongdaCore `1.10.8`。

## V1.6.20 — 2026-08-28

### 断线恢复与后台性能

- Service/Core 在运行中意外退出后，客户端先恢复 Windows 代理状态，再按
  2 / 4 / 8 秒退避自动重连，最多三次；手动断开不会触发自动恢复。
- 新增“断线自动恢复”设置，默认开启并可持久关闭。
- 窗口隐藏、暂停或退出前台时停止仪表盘采样和顶层重绘；网络核心与流量统计继续运行，
  恢复窗口后一次性刷新状态。

### 连接日志与规则集

- `/connection-log` 改为游标增量：活动连接保持实时更新，关闭历史只传输新增或变化行；
  Flutter 最多每五秒合并一次，避免重复解析 1000 条完整 JSON。
- 每个远程规则集新增 jsDelivr 备用域名和 GitHub Raw 后备源。
- 首次安装没有规则缓存且所有下载源暂不可用时，以空的可选规则集继续启动；由于智能
  分流最终出站为当前节点，此时流量安全地走代理而不是误直连或卡死 Doctor。
- 版本：鸿达星轨智连 `1.6.20+180`，HongdaService `1.5.7`，HongdaCore `1.10.7`。

## V1.6.19 — 2026-08-27

### 浏览器与分流性能

- 修复 DoH 每次查询都重新建立 VLESS/WebSocket/TLS 连接的问题：Core 现在复用
  HTTP/2/HTTP/1.1 DoH 长连接、合并相同并发问题并按 TTL 缓存响应；IPv4-only
  内部判定不再串行查询无用的 AAAA。
- 智能分流与 Karing 当前配置对齐为“国内/下载直连，其余走节点”；新增
  `Download.srs` 与 Windows Update/Delivery Optimization 内置直连规则，避免几十个
  更新连接占满 VLESS 带宽。V1.6.18 现场约 600 MB 更新流量误走节点。
- Windows gVisor TUN 默认 MTU 调整为 Karing 同值 `4064`，减少用户态栈的分包和
  系统调用开销；旧配置通过 Windows TUN profile 6 自动迁移。

### 稳定性与界面

- 修复 Flutter 原生 `/traffic`、`/connections` WebSocket 不带 Origin 时返回 403；
  浏览器非回环 Origin 仍拒绝，连接监控不再降级为 HTTP 轮询。
- Wintun 遇到异常退出残留地址时精确清理 HongdaTun 地址并重试一次，修复
  `The object already exists` 偶发启动失败。
- 左侧品牌副标题改为自适应缩放，正常窗口宽度完整显示“极速连接 · 智能路由”。
- 版本：鸿达星轨智连 `1.6.19+179`，HongdaService `1.5.6`，HongdaCore `1.10.6`。

## V1.6.18 — 2026-08-26

### 过期节点证书兼容与错误诊断

- 实测当前 `vless-da` 代理入口证书有效期为 2026-08-16 至 2026-08-22，故所有
  经该节点的请求都会在进入 WebSocket 前失败；目标网站证书并未过期。
- 对照 Karing 实际运行配置确认其全局 `enable_insecure=true` 会给节点加入
  `tls.insecure=true`；Hongda 之前缺少等价设置。
- 连接设置新增显式 TLS 兼容开关，默认关闭。开启后仅忽略代理入口的过期/自签名
  证书，目标网站 HTTPS 证书继续严格校验。
- HongdaCore 握手错误新增代理端点及 TLS/WebSocket/gRPC 阶段，避免错误归因。
- 新增回归测试，确认该开关为 opt-in、不会污染保存的节点数据。
- 应用版本：`1.6.18+178`；HongdaService：`1.5.5`；HongdaCore：`1.10.5`。

## V1.6.17 — 2026-08-26

### 启动容错与低高度仪表盘修复

- 修复 Selector 已切换成功后，单一 gstatic 延迟探针因证书异常返回 503，客户端却
  将其当成节点切换失败并主动停止 HongdaService 的启动回归。
- Selector 的 PUT/GET 状态确认仍是硬校验；URLTest 改为多目标降级，全部失败仅记录
  警告。TUN 的真实 HTTPS 验证继续严格校验证书，未使用 `InsecureSkipVerify`。
- 新增两项回归测试，覆盖 HTTPS 证书异常后的备用探针以及全部测速失败不抛出异常。
- 仪表盘按可用高度增加超紧凑布局：缩小连接状态、流量图和快捷按钮，只显示一个
  最近节点，同时保留全部模块及极小窗口滚动兜底。
- 普通窗口默认占用工作区 92%×94%，减少 1366×768 与高 DPI 环境下必须最大化的情况。
- 应用版本：`1.6.17+177`；HongdaService：`1.5.4`；HongdaCore：`1.10.4`。

## V1.6.16 — 2026-08-26

### Clash Verge 对照审查与连接监控优化

- 对照 Clash Verge 的连接订阅机制，HongdaCore 新增 `/connections` WebSocket：
  首帧立即返回，随后每秒推送活动连接和累计流量。
- Flutter 优先使用连接实时流；流超过 4 秒没有数据时自动回退 HTTP，1 秒后重连，
  连接日志历史仍由 `/connection-log` 保证完整。
- 修复连接关闭时间在网络线程写入、API 线程读取时的数据竞争窗口。
- 清理无引用组件并迁移 Flutter 新版 API，`flutter analyze` 从 30 项问题降为 0。
- 保持现有 TUN、路由与远程 DoH 行为不变；Clash Verge 的 DNS `respect-rules`
  默认同样关闭，因此没有把已验证无泄漏的 DNS 改回物理网卡解析。
- 应用版本：`1.6.16+176`；HongdaService：`1.5.4`；HongdaCore：`1.10.4`。

## V1.6.15 — 2026-08-21

### v2rayN 风格连接日志

- 侧边栏新增“连接日志”，日志中心保留“运行日志 / 连接日志”快速切换。
- 表格实时显示活动和最近关闭连接：状态、开始时间、TCP/UDP、目标域名与 IP、
  实际出站节点、命中规则、上传、下载和总流量。
- 支持域名/IP/协议/节点/规则筛选、立即刷新、复制为 TSV 和清除已关闭历史。
- HongdaCore 为每条连接保存来源、DNS/SNI 域名、原始目标、逻辑路由、选择器实际
  节点和规则编号；`/connection-log` API 返回活动连接及最近 1000 条关闭记录。
- `/connections` 继续只返回活动连接，原有活动数量与实时流量统计语义不变。
- 使用当前实际选中的 VLESS 节点完成 gstatic/YouTube 联网及连接元数据实测。
- 应用版本：`1.6.15+175`；HongdaService：`1.5.3`；HongdaCore：`1.10.3`。

## V1.6.14 — 2026-08-21

### 生产 TUN IPv6 回归修复

- 现场生成的 V1.6.13 配置仍是 `ipv6Enabled=true / prefer_ipv4`；Google/YouTube
  因此继续选择 AAAA，节点没有可用 IPv6 出口时表现为“连接成功但无法代理”。
- Windows TUN 的 IPv4-only 改为配置生成器硬约束：即使旧 `settings.json` 保存了
  IPv6，DNS 也固定抑制 AAAA、TUN 继续接管 IPv6 split routes 并在核心内拒绝
  公网 IPv6，不再依赖一次性迁移是否成功。
- 不再下载或执行 ChinaIpV6 直连规则，防止旧开关重新放行物理 IPv6。
- TUN 设置配置迁移到版本 5；启动后会把旧 IPv6/`prefer_ipv4` 设置改回
  `false`/`ipv4_only`。
- 客户端日志新增持久化到 `%APPDATA%\HongdaStarlink\runtime\client.log`，程序退出后
  仍可检查启动、路由验证、真实联网与自动断开原因。
- 隔离实测当前选中的 `vless-da` 可通过 HongdaCore 访问 gstatic 与 YouTube；节点
  协议数据面正常，问题位于生产 TUN 配置而非 VLESS 节点。
- 应用版本：`1.6.14+174`；HongdaService：`1.5.2`；HongdaCore：`1.10.2`。

## V1.6.13 — 2026-08-21

### TUN 分流、YouTube 与 IPv6 泄漏修复

- 修复核心分流缺陷：TUN TCP/UDP 建连只携带目标 IP，旧版没有保存被劫持 DNS
  响应中的“域名 → IP”关系，导致 YouTube、Google 等域名规则在真实连接阶段失效，
  最终错误落入 `final=direct`。
- HongdaCore 记录 DoH 返回的 A/AAAA 与原查询域名，并按 DNS TTL 建立有界反向缓存；
  后续 IP 连接可重新执行域名、后缀与远程规则集匹配。
- 对 TCP/443 增加无损 TLS ClientHello SNI 识别，覆盖浏览器启用加密 DNS、核心看不到
  A/AAAA 查询的场景；只用域名选择出站，实际仍连接原目标 IP。
- `youtube.com`、`googlevideo.com`、`ytimg.com`、Google API/静态资源等关键后缀改为
  本地高优先级代理规则，不再依赖远程规则集是否完整。
- Windows TUN 始终接管 IPv4/IPv6 split routes；默认切换到 IPv4-only，在 TUN 内
  明确拒绝 IPv6，避免物理网卡 IPv6 绕行，并使 Happy Eyeballs 回退到受控 IPv4。
- TUN 下拒绝公网 UDP/443，使不兼容 QUIC 的 VLESS 节点快速回退到 TCP/TLS，修复
  YouTube 长时间等待或打不开，同时不影响 TCP/443。
- 应用版本：`1.6.13+173`；HongdaService：`1.5.2`；HongdaCore：`1.10.2`。

## V1.6.12 — 2026-08-21

### OpenAI 规则集 404 修复

- V1.6.11 新增的独立 `OpenAi.srs` 在部分 jsDelivr 出口边缘返回 404，导致没有
  有效缓存时 `HongdaService doctor` 拒绝启动。
- 移除这项重复远程依赖；`openai.com`、`chatgpt.com`、`oaistatic.com` 和
  `oaiusercontent.com` 改为本地配置内置高优先级代理规则。
- ProxyLite 与 ProxyGFWlist 继续覆盖 Google、YouTube、OpenAI 及常见受限站点，
  Karing 式 `final=direct` 行为不变。
- 应用版本：`1.6.12+172`；HongdaService：`1.5.1`；HongdaCore：`1.10.1`。

## V1.6.11 — 2026-08-21

### 退出代理恢复修复

- 现场确认 Windows 系统代理残留为 `127.0.0.1:3067` 且没有进程监听；旧逻辑把
  TUN 启动前保存的本地代理无条件重新启用，导致 Hongda/Karing 退出后浏览器断网。
- 恢复 `localhost`、`127.0.0.1`、`::1` 代理前检查对应 TCP 端口；端口已失效时
  恢复为直连。远程/企业代理和无法识别的 Windows 代理格式保持原样。
- 代理恢复快照新增托管绕过列表，恢复前同时比对启用状态、服务器和绕过列表；
  用户或其他代理程序在 Hongda 运行期间改过设置时不覆盖其新状态。
- 正常退出、Service 异常、启动失败和下次启动崩溃恢复继续共用持久化快照。

### Karing 式选择性分流

- 根因是旧版智能分流的 `route.final=proxy`：普通国外检测站即使未命中代理规则，
  仍显示节点 IP；Karing 的同类选择性分流会让未命中流量直连。
- 智能分流改为 `final=direct`：中国域名/IP 直连，OpenAI、ProxyLite、
  ProxyGFWlist 命中走当前节点，普通国外站点未命中时直连。
- OpenAI 规则放在中国域名/IP 规则之前，China IP 仍位于代理列表之后；IPv6 开启
  时加载 ChinaIpV6，减少共享 CDN、污染 DNS 和 IPv6 对规则优先级的干扰。

### 版本

- 应用版本：`1.6.11+171`；HongdaService：`1.5.1`；HongdaCore：`1.10.1`。

## V1.6.10 — 2026-08-14

### Windows TUN 路由误判修复

- 根因为 HongdaCore 为 VLESS 服务器 IP 添加物理网卡 `/32` 绕行后，Windows
  会将 `0.0.0.0/1` 和 `128.0.0.0/1` 拆成多条更细的等价前缀；旧版只计数
  字面 `/1` 路由，因此在 TUN 已经正常接管时仍判定失败并主动停止 Service。
- 原生 Windows 检查改为对 IPv4 低半区、高半区各使用两个公共地址查询
  `GetBestInterface`；两个半区均由 HongdaTun 接管才会显示已就绪。
- 保留原有默认路由和 `/1` 计数用于诊断，新增端点绕行分段路由的明确状态文案。
- 新增两项回归测试：允许没有字面 `/1` 的完整端点绕行路由；拒绝只接管
  IPv4 一个半区的不完整路由。

### 窗口标题与并发操作修复

- 侧边栏软件名改为独占首行，紧凑版本徽标移到副标题行，不再因
  `V1.6.10` 宽度把“鸿达星轨智连”压到不可见。
- 连接/断开和运行时节点切换增加单飞保护；启动或停止期间的重复点击
  不再同时启动多个 Service，避免 7890 端口冲突和 Wintun 重复创建。
- HongdaCore 1.10.1 的 `DELETE /connections` 改为立即确认、后台关闭旧 socket，
  修复节点切换时“清理旧连接”等待 6 秒超时。

### 版本

- 应用版本：`1.6.10+170`；HongdaService：`1.5.1`；HongdaCore：`1.10.1`。

## V1.6.9 — 2026-08-14

### HongdaCore 1.10 集成

- HongdaService 升级到 1.5.0，并内嵌独立 HongdaCore 1.10.0。
- Windows 生成的五组 Karing 规则集已通过真实 `doctor`：远程下载、严格解析、原子
  缓存、周期更新和有效旧缓存回退均由 Core 执行。
- 首次规则下载限制两路并发，并对超时、429、5xx 增加一次有限重试，修复空缓存
  场景下 ChinaIp 下载偶发超时导致启动失败。
- TUN DIRECT 出站绑定物理默认网卡，解决中国直连规则重新进入 HongdaTun 的回环。
- 同时劫持 UDP/TCP 53 到代理 DoH；IPv4-only 模式抑制 AAAA，避免物理 IPv6 泄漏。
- BanAD/域名 REJECT 在 DNS 阶段直接返回 NXDOMAIN，不再因 TUN 建连只剩 IP 而失效。
- 修复 API Secret 启用后 `/traffic?token=` 被拒绝导致实时流量图无数据。
- 动态 Mixed/API 端口、节点运行时切换复核与关闭旧连接流程继续保留。
- Tailscale endpoint 尚未实现，旧设置自动关闭，UI 明确显示开发中。
- 混合订阅中的未支持协议不再拖垮已选 VLESS；VMess/Shadowsocks 不进入运行配置，
  直接选择时给出明确错误。进程规则与 FakeIP 同样不再伪装为可用。
- Core 配置体检新增节点服务器/端口、REALITY 必填字段和 transport 校验；HTTP
  transport、Hysteria2 obfs、TUIC 非 cubic/非 native 参数及 multiplex 会在启动前
  给出明确错误，不再被静默忽略。
- 删除无用 `libcronet.dll`，自包含 Service 约 17 MB。
- 关闭 Karing 后的独立管理员 HongdaTun 实测通过：国外代理、国内 DIRECT、
  UDP/TCP 53 → DoH 与流量统计均成功（上传 79,544、下载 2,741,813 字节）。

### 版本

- 应用版本：`1.6.9+169`；HongdaService：`1.5.0`；HongdaCore：`1.10.0`。

## V1.6.8 — 2026-08-14

### 修复与增强

- 修复仪表盘中间“实时流量”曲线始终为空的问题：`uploadHistory`/`downloadHistory` 使用固定长度列表却调用 `removeAt`，采样定时器每秒抛异常导致历史数据永远为零；改为滑动赋值，并修复迷你曲线 `shouldRepaint` 原地修改列表时不再重绘的问题。
- 修复 Clash API `/traffic` WebSocket 使用 `Authorization` 头鉴权的问题，改为 Clash 规范的 `?token=` 查询参数，保证设置 API Secret 后实时流量仍可用。
- 修复节点国家/地区识别误判：`free`、`this`、`phone`、`running` 等常见英文单词不再被当作 FR/TH/PH/RU 等国家码。
- 修复 Shadowsocks SIP002 订阅密码未做 base64 解码导致部分节点无法连接的问题，同时兼容明文密码。
- 修复 DNS 泄露与谷歌/Facebook/Twitter 分流失败：DNS 默认由系统解析器迁移为“DoH 且经代理”，路由顺序调整为“中国域名直连 → 代理列表 → 中国 IP 直连”，避免污染 IP 抢在域名规则前把被墙域名判成直连。
- 修复 fakeip DNS 缺少上游 `server` 字段。
- 关闭 TUN 后自动恢复“系统代理”开关。
- `SingBoxController.dispose` 主动终止残留核心进程，降低热重启场景下的子进程泄漏风险。
- 原生 Windows 系统代理恢复增加“用户手动改过代理则不覆盖”的保护，与崩溃恢复分支行为一致。
- 发布脚本自动打包 MSVC 运行库 `vcruntime140.dll`/`vcruntime140_1.dll`/`msvcp140.dll`，解决开发机正常、干净机器因缺少 VC++ 运行时无法启动的问题。

### 版本

- 应用版本：`1.6.8+168`；HongdaService：`1.4.2`；HongdaCore：`1.13.18`。

## V1.6.7 — 2026-08-13

### Windows TUN 与运行时切换修复

- 修复 TUN 和 `127.0.0.1` Windows 系统代理叠加时，浏览器可用但 ChatGPT 等 AppContainer/WebView 应用无法访问本机代理的问题；TUN 期间临时暂停任何现有系统代理，断开或下次异常恢复时原样还原。
- TUN 配置迁移为严格路由、mixed 栈、MTU 1500、IPv4/IPv6 双栈 split routes。
- 原生路由检查增加 Windows 最优路由校验；启动阶段增加真实 HTTPS TUN 联网探针，探针失败不显示“已连接”。
- 运行中切换节点严格要求 Clash selector 返回目标 tag，主动关闭旧连接，再通过 selector URLTest 验证实际代理链路；失败自动回滚。
- 应用版本：`1.6.7+167`；HongdaService：`1.4.2`；HongdaCore：`1.13.18`。

## V1.6.6 — 2026-08-13

### Windows 回归修复

- 修复 `jpda`、`hk01` 等连写线路名称无法识别国家；增加节点地区手动覆盖。
- 增加用户确认后的服务器 IP 国家定位与本地缓存，不上传节点凭据。
- 修复 TCP 端口可达被误画成红色失败；节点状态现在区分已连接、代理可用、TCP 可达、失败、未测试和禁用。
- 修复实时流量仅统计轮询时仍活跃的连接，导致大量短连接未进入曲线；改用 Clash 顶层累计字节计数。
- WebSocket 流量帧兼容文本和二进制数据；曲线增加当前值和面积填充。
- Windows TUN 改为 mixed 栈、MTU 1500、IPv4 split routes，并迁移 V1.6.5 的不稳定默认组合。
- 新增 Windows 原生 TUN 网卡和系统路由验证；路由未就绪时启动失败并给出明确原因。

### 验证

- 新增国家识别、旧状态迁移、TUN 配置和 Clash 累计流量回归测试。
- 应用版本：`1.6.6+166`；HongdaService：`1.4.2`；HongdaCore：`1.13.18`。

## V1.6.5 — 2026-08-13

### Windows UI

- 修复节点国家不显示：扩大国家识别范围，使用自绘国家徽标代替 Windows 不完整的旗帜 Emoji。
- 修复普通窗口仪表盘必须下拉或最大化：新增紧凑/超紧凑高度布局，低高度窗口保持桌面网格。
- 国家名称加入节点搜索条件。

### 连接与监控

- 修复手动 VLESS 已连接但右侧实时流量图为空：`/traffic` 异常时使用 `/connections` 真实字节增量回退。
- 修复流量 WebSocket 反复断线后可能堆积重复重连的问题。
- Mixed 与 Clash API 端口支持冲突自动避让，实际端口同步到全部调用方并持久化。

### 节点与订阅

- 订阅更新时按完整配置、身份和唯一端点匹配旧节点。
- 保留节点 ID、收藏、启用状态、延迟时间和测试错误，避免当前选择失效。

### 核心与 Service

- `HongdaService` 升级到 1.4.2。
- Windows 子核心改为从本地源码构建的 `HongdaCore.exe` 1.13.18。
- 进程关系保持 `Hongda Starlink.exe -> HongdaService.exe -> HongdaCore.exe`。
- 删除旧的重复预编译核心资源，保留第三方许可证和必要来源说明。

### 验证

- `HongdaCore.exe version`：1.13.18。
- `HongdaService.exe version/features`：通过。
- Flutter 静态分析：无编译错误。

## 历史版本

- V1.6.4：见 `V1.6.4_BUGFIX_CHANGELOG.md` 与 `V1.6.4_R2_REGRESSION_FIX.md`。
- V1.6.3：见 `V1.6.3_BUGFIX_CHANGELOG.md`。
