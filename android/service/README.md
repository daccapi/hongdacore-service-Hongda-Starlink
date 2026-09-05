# HongdaService (Windows)

`HongdaService.exe` is Hongda Starlink's Windows supervisor process. It does **not** rename sing-box and it does **not** link sing-box Go packages into the wrapper. The wrapper embeds the official sing-box 1.13.18 Windows amd64 executable plus `libcronet.dll` as binary assets.

At runtime the service verifies and extracts those assets under:

```text
%LOCALAPPDATA%\HongdaStarlink\runtime\1.13.18\
```

It then runs `sing-box check` before startup, launches sing-box as a child process, exposes JSON-lines IPC over stdin/stdout, forwards core logs to stderr, and supervises the child with a Windows Job Object configured with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. If HongdaService is terminated, Windows closes the job handle and terminates the supervised sing-box child as well.

## Bundled core capabilities

The embedded core is the official sing-box 1.13.18 Windows amd64 build used by this source package. The service advertises the capabilities expected by the Flutter client, including VLESS/Reality, Hysteria2/TUIC, Tailscale, Clash API, WireGuard, ACME, DHCP, gVisor and related full-build features.

## Commands

```powershell
HongdaService.exe version
HongdaService.exe features
HongdaService.exe doctor -c <config.json>
HongdaService.exe check  -c <config.json>
HongdaService.exe run    -c <config.json>
```

`doctor` and `check` emit one structured `HONGDA_ERROR` frame for a failure. `run` emits `HONGDA_READY` only after the child core has started and been attached to supervision.

## Build

From the project root on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\build-service.ps1
```

The wrapper requires Go 1.23+ and builds with `CGO_ENABLED=0`, `GOOS=windows`, `GOARCH=amd64`. The official core and Cronet DLL must already exist in `service\embedded`.

## License

sing-box is GPL-3.0-or-later. When distributing a package containing sing-box, preserve the applicable upstream license notices and satisfy the corresponding source-distribution obligations.
