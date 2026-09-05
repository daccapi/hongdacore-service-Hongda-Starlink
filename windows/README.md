# 鸿达星轨智连 V1.6.6 — Windows 源码

鸿达星轨智连 Windows 客户端，采用 Flutter 桌面 UI、独立 `HongdaService.exe` 监管进程和本地源码构建的 `HongdaCore.exe`。应用版本为 **1.6.6+166**，Service 版本为 **1.4.2**，核心兼容版本为 **1.13.18**。

## 运行架构

```text
Hongda Starlink.exe
  └─ HongdaService.exe 1.4.2
       └─ HongdaCore.exe 1.13.18
            ├─ VLESS / Reality / Hysteria2 / TUIC / WireGuard
            ├─ TUN / DNS / Router / Selector / URLTest
            └─ Clash API: 127.0.0.1:<运行时 API 端口>
```

Flutter 负责节点、订阅、配置生成、启动编排、stdio JSONL IPC、Clash API 和 Windows 系统代理。`HongdaService.exe` 负责释放并启动 `HongdaCore.exe`，将其加入 kill-on-close Windows Job Object，避免 Service 异常退出后遗留核心进程。

`HongdaCore.exe` 由 `tools/build-core.ps1` 从相邻 Android R9 项目的 `core/sing-box` 本地源码树构建，随后作为资源嵌入 `HongdaService.exe`。上游许可证和归属保留在源码树及 `LICENSE-sing-box.txt` 中。

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
Go 1.24.7+
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

默认运行包输出为 `dist\Hongda-Starlink-V1.6.6-Windows-x64.zip`。详细步骤见 [BUILD_WINDOWS.md](BUILD_WINDOWS.md)。

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

## 目录说明

```text
lib/                    Flutter UI、节点/订阅/配置和控制逻辑
service/                HongdaService Go 源码与嵌入资源
service/embedded/       HongdaCore.exe、libcronet.dll
runtime/service/        发布时携带的 HongdaService 与第三方声明
tools/                  核心、Service、Windows 发布构建脚本
windows/                Flutter Windows Runner 与原生集成
third_party/sing-box/   可选的本地上游源码位置说明
```

## 第三方说明

Hongda 品牌覆盖应用自身的 UI、服务封装、构建链和集成代码。网络核心基于上游项目修改/构建；版权与许可证文件必须保留。仅内部自用不等于第三方版权归属消失，若将二进制提供给他人，应重新检查对应许可证义务。
