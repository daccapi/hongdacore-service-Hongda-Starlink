# 鸿达星轨智连 V1.6.5 — Windows 构建

## 目标环境

```text
Flutter 3.44.4 stable
Dart    3.12.2
Go      1.23+
Windows 10/11 x64
Visual Studio 2022（使用 C++ 的桌面开发）
```

## 组件与运行链

```text
Hongda Starlink.exe V1.6.5
  -> HongdaService.exe 1.4.2
  -> HongdaCore.exe 1.13.18
  -> VLESS / Reality / Hysteria2 / Clash API
```

`HongdaCore.exe` 由本仓库固定的 sing-box 1.13.18 源码构建，产物采用项目自有名称；这不改变底层第三方源码的许可证和版权归属。Service 通过 Go `embed` 内嵌：

```text
service\embedded\HongdaCore.exe
service\embedded\libcronet.dll
```

运行时释放到 `%LOCALAPPDATA%\HongdaStarlink\runtime\1.13.18\`，执行配置检查，再把 Core 加入 kill-on-close Windows Job Object。

## 构建 Core 与 Service

```powershell
# 从 Android 兄弟目录的固定 sing-box 源码构建 HongdaCore.exe
powershell -ExecutionPolicy Bypass -File .\tools\build-core.ps1

# 构建并验证 HongdaService.exe 1.4.2
powershell -ExecutionPolicy Bypass -File .\tools\build-service.ps1
```

验证：

```powershell
.\runtime\service\HongdaService.exe version
.\runtime\service\HongdaService.exe features
```

如 `service\embedded\HongdaCore.exe` 已准备好，可使用 `build-service.ps1 -SkipCoreBuild`。

## 一键构建 Windows Release

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

脚本依次构建 Core、Service、Flutter Windows Release，复制运行时文件并生成：

```text
dist\Hongda-Starlink-V1.6.5-Windows-x64.zip
```

仅构建 UI 且复用已验证 Service：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -SkipServiceBuild
```

## 启动流程

```text
1. 选择节点并解析可用 Mixed / Clash API 端口
2. 生成 %APPDATA%\HongdaStarlink\runtime\config.json
3. HongdaService doctor -c config.json
4. HongdaService run -c config.json
5. 等待 HONGDA_READY 与 Clash API /version
6. 强制同步并校验当前 selector 节点
7. 建立 stdin/stdout JSON IPC
8. 按设置启用 Windows 系统代理
9. 采集 /traffic；必要时由 /connections 增量回退
```

7890 和 9090 是首选值，不是硬编码必占端口。被占用时会尝试相邻端口，最后可由系统分配空闲端口；实际端口统一回写到设置、配置与状态页。

## 权限与许可证

系统代理模式不要求管理员权限。启用 TUN 或 Tailscale 时需要管理员权限。

HongdaCore 基于 sing-box 1.13.18 源码构建。源码包和发布包必须保留适用的 GPL-3.0-or-later 许可、版权声明、对应源码及修改说明；不能以可执行文件改名替代这些义务。
