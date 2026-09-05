package protocol

import (
	"context"
	"net"
	"sync/atomic"

	"hongda.local/hongda-core/model"
)

// Direct implements model.Outbound as a plain system dialer.
type Direct struct {
	id             string
	interfaceIndex atomic.Int64
}

func NewDirect(id string) *Direct {
	return &Direct{id: id}
}

func (d *Direct) ID() string               { return d.id }
func (d *Direct) Type() model.ProtocolType { return model.ProtocolDirect }
func (d *Direct) SupportUDP() bool         { return true }
func (d *Direct) Close() error             { return nil }

func (d *Direct) SetInterfaceIndex(index int) {
	d.interfaceIndex.Store(int64(index))
}

func (d *Direct) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	dialer := net.Dialer{Control: interfaceControl(int(d.interfaceIndex.Load()))}
	conn, err := dialer.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}
	return conn, nil
}

func (d *Direct) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	listenConfig := net.ListenConfig{Control: interfaceControl(int(d.interfaceIndex.Load()))}
	return listenConfig.ListenPacket(ctx, "udp", address)
}

// Keep a compile-time assertion that Direct satisfies the interface.
var _ model.Outbound = (*Direct)(nil)
var _ model.InterfaceAware = (*Direct)(nil)
