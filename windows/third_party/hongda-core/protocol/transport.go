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
	base, err := dialTLS(ctx, host, port, tlsOpts)
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
		grpcBase, grpcErr := dialTLSWithNextProtos(ctx, host, port, tlsOpts, []string{"h2"})
		if grpcErr != nil {
			return nil, fmt.Errorf("proxy endpoint %s gRPC TLS handshake: %w", net.JoinHostPort(host, fmt.Sprint(port)), grpcErr)
		}
		return grpcDial(ctx, grpcBase, host, port, transport)
	case "http", "h2":
		return nil, fmt.Errorf("transport %q not implemented yet", transport.Type)
	default:
		_ = base.Close()
		return nil, fmt.Errorf("transport %q not implemented", transport.Type)
	}
}
