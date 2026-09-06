# 构建与验证

构建前查看对应组件的版本说明。不要为测试而自动停止正在使用的 Karing 或启动第二个 TUN。

## Windows

需要 Flutter、Visual Studio C++ 桌面工具链、CMake 与 Go。Core 构建脚本固定 Go 1.25.0。

```powershell
cd windows
flutter pub get
flutter analyze
flutter test
.\tools\build-release.ps1
```

默认从相邻 `hongda-core/` 构建 Core，嵌入 Service，再生成 Flutter 程序。
源码 Git 树不携带预编译 EXE，不能跳过首次 Core/Service 构建。

## Core

```powershell
cd hongda-core
go test ./...
go test -tags with_gvisor ./...
go vet -tags with_gvisor ./...
.\build-windows.ps1
```

上述测试中的真实节点/TUN 集成测试是显式启用项。不要设置 HONGDA_LIVE_CONFIG 或
HONGDA_LIVE_TUN，除非已安排好单独的联网测试并确保不会与当前代理冲突。

## Android

需要 Flutter、Java、Android SDK/NDK 及 Go；详见 [Android 原始构建文档](../android/BUILD_ANDROID.md)。

```powershell
cd android
.\tools\build-android-core.ps1
.\tools\build-android-release.ps1
```

`core/sing-box/` 保留本项目使用的 libbox 派生源码和上游声明。构建脚本包含 gomobile
Windows 环境兼容补丁。历史 APK 使用调试签名；正式分发需自己配置安全的 release 签名，
签名私钥不要提交 Git，也不要作为 Release 附件。

## 历史版本

下载所选版本的原名 Source.zip；不要用当前 Core 替换历史版本要求的嵌入核心并声称完全可复现。
部分早期包携带预编译嵌入组件，相关上游源码及许可补充见 THIRD_PARTY_NOTICES.md。
本次未重新编译或实测所有旧版本，不保证旧版工具链/外部下载地址今天仍能正常使用。
