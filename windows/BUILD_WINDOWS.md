# 鸿达星轨智连 V1.6.14 — Windows 构建

## 目标环境

```text
Flutter 3.44.4 stable
Dart    3.12.2
Go      1.25.0
Windows 10/11 x64
Visual Studio 2022（使用 C++ 的桌面开发）
```

## 组件与运行链

```text
Hongda Starlink.exe V1.6.14
  -> HongdaService.exe 1.5.2
  -> HongdaCore.exe 1.10.2
  -> VLESS / Reality / Hysteria2 / Clash API
```

`HongdaCore.exe` 由相邻 `hongda-core` 源码构建。协议、路由与控制面不导入 sing-box 运行时代码；Windows TUN 链接的 sing-tun、gVisor 与嵌入的 Wintun 仍保留各自许可证。Service 通过 Go `embed` 内嵌：

```text
service\embedded\HongdaCore.exe
```

运行时释放到 `%LOCALAPPDATA%\HongdaStarlink\runtime\1.10.2\`，执行配置与远程规则集检查，再把 Core 加入 kill-on-close Windows Job Object。

## 构建 Core 与 Service

```powershell
# 从相邻 hongda-core 源码构建 HongdaCore.exe
powershell -ExecutionPolicy Bypass -File .\tools\build-core.ps1

# 构建并验证 HongdaService.exe 1.5.2
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
..\Hongda-Starlink-V1.6.14-Windows-x64.zip
```

仅构建 UI 且复用已验证 Service：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -SkipServiceBuild
```

源码包（嵌入 `third_party/hongda-core` 源码，不包含生成的 EXE/DLL/PDB）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\package-source.ps1
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

系统代理模式不要求管理员权限。启用 TUN 时需要管理员权限。Tailscale endpoint 在
1.6.14 中尚未实现，旧设置会迁移为关闭。

发布包必须保留 `NOTICE.md`、sing-tun GPL、gVisor Apache 与 Wintun 预编译许可；
不能以可执行文件改名替代这些义务。
