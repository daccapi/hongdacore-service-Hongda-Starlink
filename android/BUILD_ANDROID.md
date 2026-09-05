# 鸿达星轨智连 Android 构建说明

## 当前版本

- App 版本：1.6.4+164
- Flutter：项目声明 `>= 3.44.0`
- Android 最低版本：API 24（Android 7.0）
- Android applicationId：`com.hongda.starlink`

## 已完成

- 按 `design/reference-ui.png` 重构 Android 首页：品牌头部、蓝色星轨连接卡、连接环、实时指标、流量曲线、快捷设置、订阅卡、近期节点、5 项底部导航。
- 新增 Android 专用节点、订阅、工具、设置页面。
- 复用原工程的订阅解析、节点解析、规则组、配置生成、URLTest 数据模型与持久化。
- 新增 Android `MethodChannel`、`VpnService` 原生工程骨架，并将 Android 数据目录改到应用私有目录。
- Windows 入口与 `HongdaService.exe` 逻辑保留，Android 不再误启动 Windows Service。

## 构建

在项目根目录执行：

```powershell
flutter pub get
flutter build apk --release
```

输出通常位于：

```text
build/app/outputs/flutter-apk/app-release.apk
```

如果首次构建时 `android/gradle/wrapper/gradle-wrapper.jar` 不存在，本工程的 `gradlew.bat` 会下载 Gradle 8.13 官方 wrapper bootstrap；Gradle 本体仍会按标准 wrapper 流程下载。

## Android sing-box 核心

原 Windows 版的 `HongdaService.exe` 内嵌 Windows sing-box 可执行文件，不能直接作为 Android VPN 核心运行。

Android 工程已经预留：

- `android/app/libs/libbox.aar`
- `MainActivity.kt` 的 VPN 授权/MethodChannel
- `HongdaVpnService.kt` 的 VpnService 壳层
- Flutter 侧 `AndroidRuntimeController`

放入与你选定 sing-box 版本一致的 `libbox.aar` 后，在 `android/app/build.gradle.kts` 取消 AAR dependency 注释，并按该版本 libbox API 把启动/停止和流量回调接到 `HongdaVpnService.kt`。

在核心未接入时，APP 不会伪装“连接成功”，而会明确提示 Android libbox 尚未打包；订阅、节点、配置与全部 UI 仍可使用。
