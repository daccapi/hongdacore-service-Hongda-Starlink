# 许可与来源说明

Hongda Core 的协议、路由与控制面为本项目实现。Windows TUN 链接并使用下列独立
第三方组件；因此不能把整个可执行文件描述为“完全原创”。

## Windows TUN 组件

- `github.com/sagernet/sing-tun`：GPL-3.0-or-later，负责 Wintun 设备、Windows
  路由/WFP 生命周期以及 gVisor 会话分发。
- `github.com/sagernet/gvisor`：Apache-2.0，提供用户态 TCP/IP 栈。
- Wintun 0.14.1 预编译 DLL：WireGuard LLC 的预编译二进制许可。

二进制 ZIP 的 `licenses/` 目录包含这些许可全文和适用的作者声明。不得删除或
改写这些声明。Wintun 官方明确要求预编译 DLL 的专有声明保持完整。

## 其他宽松许可依赖

- `github.com/refraction-networking/utls`：BSD-3-Clause
- `github.com/quic-go/quic-go`：MIT
- `golang.org/x/net`：BSD-3-Clause
- `golang.org/x/crypto`：BSD-3-Clause

这些依赖用于 TLS 指纹、HTTP/2 与 QUIC 传输。

如未来为兼容某协议而引入任何第三方组件，会在该组件目录内的 NOTICE 中单独声明。
