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
