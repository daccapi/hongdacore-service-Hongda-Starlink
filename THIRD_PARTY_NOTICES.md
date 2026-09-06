# 第三方许可与真实来源

本说明随源码与历史 Releases 一起发布。第三方原始版权、许可及附加声明必须保留。
本项目的 GPL-3.0-or-later 声明只适用于有权这样许可的项目代码，不重新许可第三方作品。

## 不同产品与时期

| 范围 | 实际组成与来源 |
| --- | --- |
| 当前 Windows Core 1.10.12 | 本仓库协议、路由、DNS、API 实现；使用下述开源库，并非所有底层组件原创 |
| Windows TUN | sing-tun、sing（GPL-3.0-or-later），SagerNet gVisor（Apache-2.0），Wintun 预编译驱动（独立二进制许可） |
| Android V1.6.4–V1.6.5 | `android/core/sing-box` 为 sing-box/libbox 派生源码，GPLv3 或后续版本，保留原始 LICENSE 及命名/关联声明 |
| 早期 Windows V1.6.4 R2–V1.6.8 | 历史 Service 包装/内嵌 sing-box。将可执行文件改名 HongdaCore 不改变其来源；部分包还包含 libcronet |
| Flutter/Dart UI 与运行时 | Flutter BSD-3-Clause、Dart SDK BSD-3-Clause；pubspec.lock 锁定 Dart 依赖。发行物的 NOTICES.Z 包含 Flutter 运行时的许可证信息 |
| uTLS / golang.org/x 系列 | BSD 类许可；具体以锁定版本内的 LICENSE 为准 |
| quic-go / qpack | MIT；具体以相应版本的 LICENSE 为准 |

## 源码和许可的获取

- 项目对应历史源码：各 Release 的原名 `Source.zip`，与同版本程序放在一起。
- Android 派生的 sing-box 源码和构建修改在其历史源码包内，当前基线另见 `android/core/sing-box/`。
- 上游 Go 模块按实际 go.mod 版本收集，许可和作者声明位于 `licenses/go-modules/`；
  [依赖索引](licenses/dependencies.json) 列出模块版本、源码校验值和适用版本。
- 补充依赖源码归档见 [依赖源码 Release](https://github.com/daccapi/hongdacore-service-Hongda-Starlink/releases/tag/dependencies-2026-09-05)。
- Wintun 预编译许可见 `hongda-core/licenses/Wintun-prebuilt-LICENSE.txt`；不得删除或修改驱动中的版权标记。
- 早期 libcronet/Chromium 相关组件须保留各自原始许可。依赖源码中的 cronet-go 构建来源与旧包的版本信息用于追溯，不能用项目 GPL 声明覆盖其全部依赖。

上游链接：[sing-box](https://github.com/SagerNet/sing-box)、[sing-tun](https://github.com/SagerNet/sing-tun)、
[gVisor](https://github.com/SagerNet/gvisor)、[Wintun](https://www.wintun.net/)、
[Flutter](https://github.com/flutter/flutter)、[uTLS](https://github.com/refraction-networking/utls)、
[quic-go](https://github.com/quic-go/quic-go)。

## 历史包原则

原始 103 个附件不改写，以保持历史 SHA-256 与二进制/源码对应关系。许可、来源补充及风险提示
作为同一 Release 的附件和说明提供。历史文档的“原创”“已验证”描述可能只适用于当时部分模块，
不能据此推断整个项目来源或今天的可用性。本次归档不是对全部历史版本的重新测试或法律认证。

## 项目授权声明

Copyright (C) 2026 Hongda Starlink contributors.

This project is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at your
option) any later version. It is distributed WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE. Third-party portions remain under
their respective licenses and copyright notices.
