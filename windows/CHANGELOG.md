# 更新记录

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
