# 鸿达星轨智连 V1.6.4 — Windows 构建

## 目标环境

```text
Flutter 3.44.4 stable
Dart    3.12.2
Go      1.23+
Windows 10/11 x64
```

还需要 Visual Studio 2022，并安装“使用 C++ 的桌面开发”。

`pubspec.yaml` 要求：

```yaml
environment:
  sdk: ">=3.12.0 <4.0.0"
  flutter: ">=3.44.0"
```

## Service 结构

`HongdaService.exe` 是 Go supervisor，不是把 `sing-box.exe` 改名，也不是把 sing-box Go 源码直接链接进 wrapper。它通过 Go `embed` 内嵌：

```text
service\embedded\sing-box.exe       # official sing-box 1.13.18 Windows amd64
service\embedded\libcronet.dll
```

运行时会释放 core，执行配置检查，并将 sing-box 子进程加入 kill-on-close Windows Job Object。

### 单独构建 Service

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-service.ps1
```

验证：

```powershell
.\runtime\service\HongdaService.exe version
.\runtime\service\HongdaService.exe features
```

源码包当前自带的 Service：

```text
Service version: 1.4.1
Go:              1.23.2 windows/amd64
Size:            57,331,712 bytes
SHA256:          caecf6bd617bd96d1c2c4b820b16b2361d620f39fa6a5177448b704fcdbab778
```

## 一键构建 Windows Release

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1
```

执行顺序：

1. 构建/确认 `HongdaService.exe`；
2. `flutter pub get`；
3. `flutter build windows --release`；
4. CMake 把 `runtime\service` 复制进 Release；
5. 验证最终 Release 内 Service 大小；
6. 默认生成 `dist\Hongda-Starlink-V1.6.4-Windows-x64.zip`。

如果使用源码包内已经重新构建的 Service：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -SkipServiceBuild
```

仅构建 Release、不生成 ZIP：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-release.ps1 -NoZip
```

## 启动链

```text
1. 定位 runtime\service\HongdaService.exe
2. 校验 Service 大小 / 版本 / features
3. 检查 TUN / Tailscale 管理员权限
4. 检查 mixed / Clash API 端口
5. 生成 runtime config.json
6. HongdaService doctor -c config.json
7. HongdaService run -c config.json
8. 等待 HONGDA_READY
9. 轮询 Clash API /version
10. stdio JSON IPC ping + status
11. 应用 Windows 系统代理
12. 启动实时流量统计
```

启动失败时 Flutter 会优先显示具体 Service phase，并在清理阶段先发 IPC `stop`；如果 wrapper 被强制结束，Windows Job Object 负责同时终止其 sing-box 子进程。

## TUN 权限

系统代理模式无需管理员权限。启用 TUN 或需要系统接口权限的功能时，如果当前进程不是管理员，UI 会提示并进行管理员重启。

## License

内嵌 sing-box 使用 GPL-3.0-or-later。分发时应保留对应许可并按其要求提供对应源码/修改说明。
