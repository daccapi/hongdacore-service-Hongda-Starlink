package protocol

import (
	"context"
	"fmt"
	"net"
	"strings"

	"hongda.local/hongda-core/model"
)

// dialTransportConn dials the server, performs TLS/REALITY/uTLS when needed,
// and then wraps the connection in the requested stream transport.
func dialTransportConn(ctx context.Context, host string, port uint16, tlsOpts *model.TLSOptions, transport *model.TransportOptions) (net.Conn, error) {
	// Select ALPN before dialing so gRPC does not leak an unused first socket.
	nextProtos := []string{"http/1.1"}
	if transport != nil && (strings.EqualFold(strings.TrimSpace(transport.Type), "grpc") || strings.EqualFold(strings.TrimSpace(transport.Type), "gun")) {
		nextProtos = []string{"h2"}
	}
	base, err := dialTLSWithNextProtos(ctx, host, port, tlsOpts, nextProtos)
	if err != nil {
		phase := "connect"
		if tlsOpts != nil && tlsOpts.Enabled {
			phase = "TLS handshake"
		}
		return nil, fmt.Errorf("proxy endpoint %s %s: %w", net.JoinHostPort(host, fmt.Sprint(port)), phase, err)
	}
	if transport == nil || strings.TrimSpace(transport.Type) == "" {
		return base, nil
	}
	switch strings.ToLower(strings.TrimSpace(transport.Type)) {
	case "raw", "tcp":
		return base, nil
	case "ws", "websocket":
		conn, wsErr := websocketDial(ctx, base, host, port, transport)
		if wsErr != nil {
			return nil, fmt.Errorf("proxy endpoint %s WebSocket handshake: %w", net.JoinHostPort(host, fmt.Sprint(port)), wsErr)
		}
		return conn, nil
	case "grpc", "gun":
		return grpcDial(ctx, base, host, port, transport)
	case "http", "h2":
		_ = base.Close()
		return nil, fmt.Errorf("transport %q not implemented yet", transport.Type)
	default:
		_ = base.Close()
		return nil, fmt.Errorf("transport %q not implemented", transport.Type)
	}
}
