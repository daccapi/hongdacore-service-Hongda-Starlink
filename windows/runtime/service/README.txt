Hongda Starlink V1.6.8 Windows service runtime

Required runtime files:
  HongdaService.exe 1.4.2
  LICENSE-sing-box.txt

HongdaService embeds HongdaCore.exe 1.13.18 and libcronet.dll. At runtime it
extracts them under %LOCALAPPDATA%\HongdaStarlink\runtime\1.13.18 and supervises
HongdaCore with a kill-on-close Windows Job Object.

Do not remove the third-party license notice from a redistributed package.
