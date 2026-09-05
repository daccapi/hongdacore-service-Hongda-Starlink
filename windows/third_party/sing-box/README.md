# Optional local HongdaCore upstream source tree

HongdaCore is built from the pinned upstream source.

For a local-source build, extract the official `SagerNet/sing-box` **v1.13.18**
source here so this path exists:

    third_party/sing-box/go.mod

When this directory contains `go.mod`, `tools/build-core.ps1` uses it. Otherwise
the script uses the canonical source tree in the adjacent Android R9 project.

Do not place a precompiled executable here. The Windows release architecture is
`Hongda Starlink.exe -> HongdaService.exe -> HongdaCore.exe`, and the last
component must be reproducibly built from this source tree.
