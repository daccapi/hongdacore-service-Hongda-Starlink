package strategy

import (
	"context"
	"net"
	"sync"

	"hongda.local/hongda-core/model"
)

// base implements the shared strategy-group plumbing. Concrete groups only
// decide which member is current.
type base struct {
	id      string
	typ     model.ProtocolType
	members map[string]model.Outbound
	order   []string

	mu      sync.RWMutex
	current string
	health  model.GroupHealth
}

func newBase(id string, typ model.ProtocolType) *base {
	return &base{id: id, typ: typ, members: make(map[string]model.Outbound)}
}

func (b *base) addMember(name string, ob model.Outbound) {
	b.members[name] = ob
	b.order = append(b.order, name)
	if b.current == "" {
		b.current = name
	}
}

func (b *base) ID() string               { return b.id }
func (b *base) Type() model.ProtocolType { return b.typ }
func (b *base) SupportUDP() bool         { return true }

func (b *base) Members() []string {
	return append([]string(nil), b.order...)
}

func (b *base) Current() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.current
}

func (b *base) Health() model.GroupHealth {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.health
}

func (b *base) currentOutbound() model.Outbound {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.members[b.current]
}

func (b *base) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	ob := b.currentOutbound()
	if ob == nil {
		return nil, net.ErrClosed
	}
	return ob.DialContext(ctx, network, address)
}

func (b *base) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	ob := b.currentOutbound()
	if ob == nil {
		return nil, net.ErrClosed
	}
	return ob.ListenPacket(ctx, address)
}

func (b *base) Close() error {
	for _, ob := range b.members {
		_ = ob.Close()
	}
	return nil
}
