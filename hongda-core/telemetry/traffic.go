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
	ID          string
	Network     string
	Host        string
	Destination string
	Upload      atomic.Int64
	Download    atomic.Int64
	closeOnce   sync.Once
	close       func()
}

// Close terminates the real sockets associated with the connection. Keeping
// the closer in the registry is important for selector changes: the control
// plane's DELETE /connections contract must interrupt existing streams,
// otherwise a UI can report a successful node switch while traffic remains on
// the old outbound.
func (c *Connection) Close() {
	c.closeOnce.Do(func() {
		if c.close != nil {
			c.close()
		}
	})
}

type Connections struct {
	mu    sync.Mutex
	items map[string]*Connection
	next  uint64
}

func NewConnections() *Connections {
	return &Connections{items: make(map[string]*Connection)}
}

func (c *Connections) Add(network, host, destination string, closeFn func()) *Connection {
	c.mu.Lock()
	c.next++
	id := c.next
	conn := &Connection{
		ID:          idStr(id),
		Network:     network,
		Host:        host,
		Destination: destination,
		close:       closeFn,
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
