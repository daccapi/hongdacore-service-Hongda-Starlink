package protocol

import (
	"context"
	"net"
	"time"

	"hongda.local/hongda-core/model"
)

// Direct implements model.Outbound as a plain system dialer.
type Direct struct {
	id string
}

func NewDirect(id string) *Direct {
	return &Direct{id: id}
}

func (d *Direct) ID() string                   { return d.id }
func (d *Direct) Type() model.ProtocolType     { return model.ProtocolDirect }
func (d *Direct) SupportUDP() bool             { return true }
func (d *Direct) Close() error                 { return nil }

func (d *Direct) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	var dialer net.Dialer
	conn, err := dialer.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}
	return conn, nil
}

func (d *Direct) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	return net.ListenPacket("udp", address)
}

// Keep a compile-time assertion that Direct satisfies the interface.
var _ model.Outbound = (*Direct)(nil)

// Ensure time import is used if the dialer later gains a timeout.
var _ = time.Second
