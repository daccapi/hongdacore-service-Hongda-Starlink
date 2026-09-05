package protocol

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"

	"hongda.local/hongda-core/model"
)

// Trojan implements the Trojan TCP outbound with basic TLS.
type Trojan struct {
	id        string
	server    string
	port      uint16
	password  string
	tls       *model.TLSOptions
	transport *model.TransportOptions
}

func NewTrojan(node model.Node) (*Trojan, error) {
	password := node.Auth["password"]
	if password == "" {
		return nil, fmt.Errorf("trojan password is required")
	}
	return &Trojan{
		id:        node.ID,
		server:    node.Server,
		port:      node.Port,
		password:  password,
		tls:       node.TLS,
		transport: node.Transport,
	}, nil
}

func (t *Trojan) ID() string               { return t.id }
func (t *Trojan) Type() model.ProtocolType { return model.ProtocolTrojan }
func (t *Trojan) SupportUDP() bool         { return false }
func (t *Trojan) Close() error             { return nil }

func (t *Trojan) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	if network != "tcp" {
		return nil, fmt.Errorf("trojan supports tcp only in this phase")
	}
	host, port, err := splitAddress(address)
	if err != nil {
		return nil, err
	}
	conn, err := dialTransportConn(ctx, t.server, t.port, t.tls, t.transport)
	if err != nil {
		return nil, err
	}

	sum := sha256.Sum224([]byte(t.password))
	header := make([]byte, 0, 96)
	header = append(header, hex.EncodeToString(sum[:])...)
	header = append(header, '\r', '\n')
	header = append(header, 0x01) // CONNECT
	header = append(header, trojanAddress(host, port)...)
	header = append(header, '\r', '\n')

	if _, err := conn.Write(header); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

func (t *Trojan) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	return nil, fmt.Errorf("trojan udp not implemented yet")
}

var _ model.Outbound = (*Trojan)(nil)
