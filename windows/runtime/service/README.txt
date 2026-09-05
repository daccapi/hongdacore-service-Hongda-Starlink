Hongda Starlink V1.6.4 service runtime

HongdaService.exe is the Windows x64 supervisor wrapper bundled with this source package.
The bundled executable was cross-built with Go 1.23.2 for windows/amd64.
It embeds the official sing-box 1.13.18 Windows amd64 sing-box.exe and libcronet.dll.

Verified bundled executable:
  Service version: 1.4.1
  Size:            57331712 bytes
  SHA256:          caecf6bd617bd96d1c2c4b820b16b2361d620f39fa6a5177448b704fcdbab778

Embedded sing-box.exe:
  Version: 1.13.18
  SHA256: 140c46d667d16b1491f6b830812e846c25aa2b18e68bd695023c69c393ad7081

On first launch HongdaService verifies/extracts its embedded runtime under
%LOCALAPPDATA%\HongdaStarlink\runtime\1.13.18, checks the supplied config,
starts sing-box as a supervised child, attaches it to a kill-on-close Windows
Job Object, and exposes stdio JSON-line IPC.

Commands:
  HongdaService.exe version
  HongdaService.exe features
  HongdaService.exe doctor -c <config.json>
  HongdaService.exe check  -c <config.json>
  HongdaService.exe run    -c <config.json>
