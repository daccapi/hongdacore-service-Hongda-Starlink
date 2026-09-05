# Optional local sing-box v1.13.18 source tree

HongdaService links sing-box from source.

For a local-source build, extract the official `SagerNet/sing-box` **v1.13.18**
source here so this path exists:

    third_party/sing-box/go.mod

Then `tools/build-service.ps1` automatically creates a temporary Go workspace
that uses this local source instead of downloading the sing-box module.

If this folder contains only this README, the script builds against the pinned
Go module `github.com/sagernet/sing-box@v1.13.18`.

Do not place the precompiled `sing-box.exe` here; it is intentionally no longer
part of the Hongda Starlink Release architecture.
