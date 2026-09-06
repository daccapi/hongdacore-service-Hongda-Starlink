# 鸿达星轨智连 · Hongda Starlink

Windows / Android 客户端、HongdaService 与 HongdaCore 的源码和历史发布归档。

## 下载与版本

| 产品 | 当前源码基线 | 历代源码及程序 |
| --- | --- | --- |
| Windows 客户端 | [V1.6.26](https://github.com/daccapi/hongdacore-service-Hongda-Starlink/releases/tag/windows-v1.6.26) · Service 1.5.13 · Core 1.10.13 | [Windows 版本目录](releases/windows.md) |
| Android 客户端 | [V1.6.5 / R9](https://github.com/daccapi/hongdacore-service-Hongda-Starlink/releases/tag/android-v1.6.5) · arm64 测试 APK | [Android 版本目录](releases/android.md) |
| Windows HongdaCore | [1.10.13](https://github.com/daccapi/hongdacore-service-Hongda-Starlink/releases/tag/core-v1.10.13) | [Core 版本目录](releases/core.md) |

本次归档收录 **59 个软件版本、107 个软件附件**。历史 ZIP/APK 放在 GitHub Releases，
不把大体积安装包放进 Git。完整下载链接、大小和 SHA-256 见 [机器可读索引](releases/index.json)。
归档日期不等于原始发布日期；没有找到的程序包不会补写成“已发布”。

> 旧版本仅用于追溯，未在本轮重新实测。Windows V1.6.11 有已知规则集 404 故障；
> Android V1.6.5 使用历史调试签名，作为测试版归档，不是生产签名发行版。

## 源码分类

```text
windows/        Flutter Windows UI、HongdaService、构建脚本与回归测试
hongda-core/    当前 Windows Go Core、协议、DNS、分流、控制面、TUN 适配
android/        Flutter Android UI、Kotlin VpnService、历史 libbox 集成源码
docs/           架构、构建、版本规则、发布与审计记录
licenses/       第三方许可、依赖版本与源码对应信息
releases/       按 Windows / Android / Core 分类的完整历史下载索引
```

Windows：Flutter UI → HongdaService → HongdaCore → Wintun/gVisor。
Android：Flutter UI → HongdaVpnService → HongdaCore.aar/libhongdacore.so → sing-box libbox。
**同名 HongdaCore 在 Android 历史版本与 Windows 当前版本中并非同一套实现。**
详情见 [架构与来源](docs/ARCHITECTURE.md)。

## 构建

Windows 在 `windows/` 执行 `tools/build-release.ps1`；默认读取相邻 `hongda-core/`。
Android 在 `android/` 执行 `tools/build-android-release.ps1`；需要 SDK、NDK、Go 和 Flutter。
Git 中不提交 AAR、EXE、APK、签名私钥或运行配置。历史源码附件可能包含原有预编译组件，
它们与原包保持一致；从 Git 构建时请按脚本重建。

参见 [构建指南](docs/BUILD.md)、[Windows 修复记录](windows/V1.6.26_PERFORMANCE_FIX.md)
和 [版本管理规则](docs/VERSIONING.md)。

## 许可证与来源

除另有声明的第三方部分外，本项目按 **GNU GPL version 3 or, at your option, any later version**
发布，即 `GPL-3.0-or-later`。完整条款见 [LICENSE](LICENSE)。本项目不提供担保。

第三方代码和预编译组件继续适用原许可证，保留其作者及来源声明，不被本项目许可替代。
请先阅读 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。不能将整个客户端、TUN 或
Android libbox 描述为完全原创；旧包中的名称/旧文档不改变真实来源。

## 使用与安全

请自行提供合法可用的节点/订阅。本仓库不提供代理账号、服务商凭据或签名私钥。
不要同时让多个 TUN 客户端接管路由；本次整理与上传没有启动 Hongda TUN 或关闭 Karing。
反馈问题前先脱敏，见 [SECURITY.md](SECURITY.md)。
