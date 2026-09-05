# HongdaService 1.5.0

`HongdaService.exe` 是 Windows 侧的独立监管进程。它嵌入本地源码构建的 `HongdaCore.exe` 1.10.0，不直接承载 Flutter UI，也不再携带未使用的 `libcronet.dll`。

支持命令：

```text
HongdaService.exe version
HongdaService.exe features
HongdaService.exe doctor -c <config.json>
HongdaService.exe check  -c <config.json>
HongdaService.exe run    -c <config.json>
```

`run` 模式先执行配置校验，再启动核心，并输出 `HONGDA_READY`。stdout 保留给 Hongda 协议帧，核心日志转发到 stderr；Flutter 与 Service 使用 stdio JSONL IPC 执行 `ping`、`status` 和 `stop`。

核心子进程加入 kill-on-close Windows Job Object。Flutter stdin 关闭、收到停止命令或 Service 被终止时，核心不会作为孤儿进程继续运行。

构建：

```powershell
powershell -ExecutionPolicy Bypass -File ..\tools\build-core.ps1
powershell -ExecutionPolicy Bypass -File ..\tools\build-service.ps1 -SkipCoreBuild
```

发布目录保留 HongdaCore `NOTICE.md`、sing-tun GPL、gVisor Apache 与 Wintun 预编译二进制许可。
