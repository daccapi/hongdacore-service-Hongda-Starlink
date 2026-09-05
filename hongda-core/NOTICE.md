# 许可与来源说明

Hongda Core（本目录）为**独立实现**，不包含、不链接、不复制 sing-box 或 mihomo
的 GPL-3.0 代码。协议与策略模块采用 Go 标准库和宽松许可依赖从零实现。

## 与 sing-box / mihomo 的关系

- 仅参考其**公开协议规范与配置格式**，用于兼容现有 UI 和订阅。
- `compat/singbox/` 只解析 sing-box JSON 格式并转换为本项目的统一模型，不含
  sing-box 源码。
- 本内核没有从 `github.com/SagerNet/sing-box` 或
  `github.com/MetaCubeX/mihomo` 复制代码。

## 宽松许可依赖

- `github.com/refraction-networking/utls`：BSD-3-Clause
- `github.com/quic-go/quic-go`：MIT
- `golang.org/x/net`：BSD-3-Clause
- `golang.org/x/crypto`：BSD-3-Clause

这些依赖仅用于 TLS 指纹与 HTTP/2 传输，不与本项目代码混入 GPL 组件。

## 上游参考

- sing-box: https://github.com/SagerNet/sing-box
- mihomo: https://github.com/MetaCubeX/mihomo

如未来为兼容某协议而引入任何第三方组件，会在该组件目录内的 NOTICE 中单独声明。
