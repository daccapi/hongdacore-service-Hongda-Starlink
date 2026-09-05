package protocol

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"

	"hongda.local/hongda-core/model"
)

// VLESS implements the VLESS TCP outbound. Reality and vision flow are added
// in a later phase; basic TLS and raw TCP are supported now.
type VLESS struct {
	id        string
	server    string
	port      uint16
	uuid      []byte
	flow      string
	tls       *model.TLSOptions
	transport *model.TransportOptions
}

func NewVLESS(node model.Node) (*VLESS, error) {
	uuidStr := node.Auth["uuid"]
	uuidBytes, err := parseUUID(uuidStr)
	if err != nil {
		return nil, err
	}
	return &VLESS{
		id:        node.ID,
		server:    node.Server,
		port:      node.Port,
		uuid:      uuidBytes,
		flow:      node.Auth["flow"],
		tls:       node.TLS,
		transport: node.Transport,
	}, nil
}

func (v *VLESS) ID() string               { return v.id }
func (v *VLESS) Type() model.ProtocolType { return model.ProtocolVLESS }
func (v *VLESS) SupportUDP() bool         { return false }
func (v *VLESS) Close() error             { return nil }

func (v *VLESS) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	if network != "tcp" {
		return nil, fmt.Errorf("vless supports tcp only in this phase")
	}
	host, port, err := splitAddress(address)
	if err != nil {
		return nil, err
	}
	conn, err := v.dialTransport(ctx)
	if err != nil {
		return nil, err
	}

	header := make([]byte, 0, 64)
	header = append(header, 0x00)
	header = append(header, v.uuid...)
	if v.flow == "" {
		header = append(header, 0x00)
	} else {
		addons := []byte("M" + v.flow)
		header = append(header, byte(len(addons)))
		header = append(header, addons...)
	}
	header = append(header, 0x01) // TCP command
	header = append(header, vlessAddress(host, port)...)

	if _, err := conn.Write(header); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

func (v *VLESS) dialTransport(ctx context.Context) (net.Conn, error) {
	return dialTransportConn(ctx, v.server, v.port, v.tls, v.transport)
}

func (v *VLESS) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	return nil, fmt.Errorf("vless udp not implemented yet")
}

var _ model.Outbound = (*VLESS)(nil)
var _ = binary.BigEndian
