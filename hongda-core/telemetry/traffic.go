package telemetry

import (
	"sync"
	"sync/atomic"
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
	ID         string
	Network    string
	Host       string
	Destination string
	Upload     atomic.Int64
	Download   atomic.Int64
}

type Connections struct {
	mu    sync.Mutex
	items map[string]*Connection
	next  uint64
}

func NewConnections() *Connections {
	return &Connections{items: make(map[string]*Connection)}
}

func (c *Connections) Add(network, host, destination string) *Connection {
	c.mu.Lock()
	c.next++
	id := c.next
	conn := &Connection{
		ID:          idStr(id),
		Network:     network,
		Host:        host,
		Destination: destination,
	}
	c.items[conn.ID] = conn
	c.mu.Unlock()
	return conn
}

func (c *Connections) Remove(id string) {
	c.mu.Lock()
	delete(c.items, id)
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

func (c *Connections) CloseAll() {
	c.mu.Lock()
	c.items = make(map[string]*Connection)
	c.mu.Unlock()
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
