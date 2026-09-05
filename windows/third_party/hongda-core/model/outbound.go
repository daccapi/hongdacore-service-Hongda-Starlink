package model

import (
	"context"
	"net"
)

// Outbound is the unified data-plane interface. Both single nodes and strategy
// groups implement it, so the Router never needs to know which one it has.
type Outbound interface {
	ID() string
	Type() ProtocolType
	DialContext(ctx context.Context, network, address string) (net.Conn, error)
	ListenPacket(ctx context.Context, address string) (net.PacketConn, error)
	SupportUDP() bool
	Close() error
}

// InterfaceAware is implemented by outbounds that can bind sockets to the
// physical adapter. Direct traffic needs this under Windows auto-route TUN to
// avoid re-entering the virtual interface.
type InterfaceAware interface {
	SetInterfaceIndex(index int)
}
