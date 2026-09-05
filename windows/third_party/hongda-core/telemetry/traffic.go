package telemetry

import (
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Traffic aggregates upload/download byte counters shared by the Router and
// the API controller. It intentionally has no upstream controller dependency.
type Traffic struct {
	upload   atomic.Int64
	download atomic.Int64
}

func (t *Traffic) AddUpload(n int64)   { t.upload.Add(n) }
func (t *Traffic) AddDownload(n int64) { t.download.Add(n) }
func (t *Traffic) Upload() int64       { return t.upload.Load() }
func (t *Traffic) Download() int64     { return t.download.Load() }

type Connection struct {
	ID          string
	Network     string
	Source      string
	Host        string
	Destination string
	Domain      string
	Route       string
	Outbound    string
	Rule        string
	StartedAt   time.Time
	ClosedAt    time.Time
	Upload      atomic.Int64
	Download    atomic.Int64
	closeOnce   sync.Once
	close       func()
}

// Close terminates the real sockets associated with the connection. Keeping
// the closer in the registry is important for selector changes: Clash's
// DELETE /connections contract must interrupt existing streams, otherwise a
// UI can report a successful node switch while traffic remains on the old
// outbound.
func (c *Connection) Close() {
	c.closeOnce.Do(func() {
		if c.close != nil {
			c.close()
		}
	})
}

type Connections struct {
	mu      sync.Mutex
	items   map[string]*Connection
	history []*Connection
	next    uint64
}

type ConnectionMetadata struct {
	Network     string
	Source      string
	Host        string
	Destination string
	Domain      string
	Route       string
	Outbound    string
	Rule        string
}

func NewConnections() *Connections {
	return &Connections{items: make(map[string]*Connection)}
}

func (c *Connections) Add(network, host, destination string, closeFn func()) *Connection {
	return c.AddDetailed(ConnectionMetadata{
		Network: network, Host: host, Destination: destination,
	}, closeFn)
}

func (c *Connections) AddDetailed(metadata ConnectionMetadata, closeFn func()) *Connection {
	c.mu.Lock()
	c.next++
	id := c.next
	conn := &Connection{
		ID:          idStr(id),
		Network:     metadata.Network,
		Source:      metadata.Source,
		Host:        metadata.Host,
		Destination: metadata.Destination,
		Domain:      metadata.Domain,
		Route:       metadata.Route,
		Outbound:    metadata.Outbound,
		Rule:        metadata.Rule,
		StartedAt:   time.Now().UTC(),
		close:       closeFn,
	}
	c.items[conn.ID] = conn
	c.mu.Unlock()
	return conn
}

func (c *Connections) Remove(id string) {
	c.mu.Lock()
	if conn := c.items[id]; conn != nil {
		delete(c.items, id)
		conn.ClosedAt = time.Now().UTC()
		c.history = append(c.history, conn)
		if len(c.history) > 1000 {
			copy(c.history, c.history[len(c.history)-1000:])
			c.history = c.history[:1000]
		}
	}
	c.mu.Unlock()
}

func (c *Connections) Snapshot() []*Connection {
	c.mu.Lock()
	out := make([]*Connection, 0, len(c.items))
	for _, conn := range c.items {
		out = append(out, conn)
	}
	c.mu.Unlock()
	return out
}

// HistorySnapshot includes active connections and up to 1000 recently closed
// connections, newest first. It backs the v2rayN-style connection log without
// changing the active-only /connections contract used by traffic metrics.
func (c *Connections) HistorySnapshot() []*Connection {
	c.mu.Lock()
	out := make([]*Connection, 0, len(c.items)+len(c.history))
	for _, conn := range c.items {
		out = append(out, conn)
	}
	out = append(out, c.history...)
	c.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		return out[i].StartedAt.After(out[j].StartedAt)
	})
	return out
}

func (c *Connections) ClearHistory() {
	c.mu.Lock()
	c.history = nil
	c.mu.Unlock()
}

func (c *Connections) CloseAll() {
	c.mu.Lock()
	items := make([]*Connection, 0, len(c.items))
	for _, conn := range c.items {
		items = append(items, conn)
	}
	c.mu.Unlock()
	for _, conn := range items {
		conn.Close()
	}
}

func idStr(v uint64) string {
	const digits = "0123456789"
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = digits[v%10]
		v /= 10
	}
	if i == len(buf) {
		i--
		buf[i] = '0'
	}
	return string(buf[i:])
}
