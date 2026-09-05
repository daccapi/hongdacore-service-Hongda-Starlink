# 协议与传输实现说明

本文只描述 Hongda Core 独立实现的客户端数据面，不包含 sing-box 或 mihomo 源码。

## TLS 分层

`protocol/tls.go` 根据统一配置选择三条路径：

1. REALITY
2. uTLS 指纹 TLS
3. 标准 Go TLS

## REALITY 客户端

REALITY 需要 `server_name`、`public_key`、`short_id` 以及非 Golang 的 uTLS 指纹。
握手流程：

1. 建立 TCP 连接。
2. 使用 uTLS 生成浏览器 ClientHello。
3. 从 ClientHello Random 与 uTLS ECDHE 私钥派生认证密钥。
4. 使用 AES-GCM 加密 SessionID，并替换 ClientHello 中的 SessionID。
5. 校验服务端 ed25519 证书签名是否为 `HMAC-SHA512(authKey, publicKey)`。

## WebSocket 传输

`protocol/transport_ws.go` 实现了独立 WebSocket 客户端：

- HTTP Upgrade 握手与 `Sec-WebSocket-Accept` 校验
- 客户端帧掩码、服务端帧解码
- 二进制帧读写

## gRPC-lite 传输

`protocol/transport_grpc.go` 实现了 V2Ray Gun 流：

- 使用 `golang.org/x/net/http2` 建立双向 HTTP/2 流
- 手写 gRPC 5 字节消息头与 protobuf `Hunk` 字段
- 不依赖完整 gRPC 运行时

## VLESS Vision

`protocol/vless_vision.go` 实现了 `xtls-rprx-vision` 的客户端 padding 兼容层：

- 握手后 TCP 写路径发送 `UUID + Command + ContentLength + PaddingLength` 帧
- Command 支持 `Continue`、`End`、`Direct`，首个数据帧写入 `End` 后转原始流
- 读路径解析服务端 padding 帧，并在 `End` / `Direct` 后回退到原始流
- VLESS Addons 使用 protobuf `Flow=1` 字段编码，响应 Addons 会被正确丢弃

## VLESS XUDP

`protocol/xudp.go` 实现了 Xray 的 Mux.Cool UDP（XUDP）客户端：

- VLESS 请求命令使用 `0x03 Mux`，目标地址为 `v1.mux.cool:666`
- 首包发送 `New` 帧（`SessionID=0`、目标地址、8 字节 GlobalID）
- 后续数据包发送 `Keep` 帧（每包携带目标地址），关闭时发送 `End` 帧
- 读路径解析服务端 `Keep` 帧并跳过地址元数据，返回纯 UDP payload
- VLESS UDP 默认使用 XUDP，`packet_encoding: packetaddr` 时回退到长度前缀帧

## Hysteria2

`protocol/hysteria2.go` 按 Hysteria 2 公开协议实现客户端：

- QUIC + HTTP/3 `POST /auth`，带 `Hysteria-Auth`、`Hysteria-CC-RX`、`Hysteria-Padding`
- TCP：QUIC bidirectional stream + `0x401` 请求与标准响应
- UDP：QUIC datagram，`Session ID / Packet ID / Fragment` 分片重组
- 使用 MIT 许可的 `github.com/quic-go/quic-go`

## TUIC v5

`protocol/tuic.go` 按 TUIC v5 公开协议实现客户端：

- TLS Keying Material Exporter 生成 256 位认证 token
- `Authenticate` 通过 unidirectional stream，`Connect` 通过 bidirectional stream
- UDP `Packet` 支持 associate ID、packet ID 与分片重组
- 地址类型支持域名、IPv4、IPv6 与 `None`
