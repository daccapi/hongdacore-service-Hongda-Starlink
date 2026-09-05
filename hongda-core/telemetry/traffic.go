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
	Upload      atomic.Int64
	Download    atomic.Int64
	Revision    atomic.Uint64
	closedMu    sync.RWMutex
	closedAt    time.Time
	closeOnce   sync.Once
	close       func()
}

// ClosedAt returns a race-free snapshot of the close timestamp. Connection
// rows are serialized while network goroutines may be removing them, so the
// timestamp cannot be read as an unprotected time.Time value.
func (c *Connection) ClosedAt() time.Time {
	c.closedMu.RLock()
	closedAt := c.closedAt
	c.closedMu.RUnlock()
	return closedAt
}

func (c *Connection) markClosed(at time.Time) {
	c.closedMu.Lock()
	c.closedAt = at
	c.closedMu.Unlock()
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
	mu       sync.Mutex
	items    map[string]*Connection
	history  []*Connection
	next     uint64
	revision uint64
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
	c.revision++
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
	conn.Revision.Store(c.revision)
	c.items[conn.ID] = conn
	c.mu.Unlock()
	return conn
}

func (c *Connections) Remove(id string) {
	c.mu.Lock()
	if conn := c.items[id]; conn != nil {
		delete(c.items, id)
		conn.markClosed(time.Now().UTC())
		c.revision++
		conn.Revision.Store(c.revision)
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
	items, _ := c.HistorySnapshotSince(0, 1000)
	return items
}

// HistorySnapshotSince always returns active connections so their byte
// counters stay current, plus recently changed closed rows after the supplied
// event cursor. This keeps the desktop connection log incremental without
// losing the active-to-closed transition of an older connection ID.
func (c *Connections) HistorySnapshotSince(after uint64, limit int) ([]*Connection, uint64) {
	if limit <= 0 || limit > 1000 {
		limit = 1000
	}
	c.mu.Lock()
	cursor := c.revision
	out := make([]*Connection, 0, len(c.items)+limit)
	for _, conn := range c.items {
		out = append(out, conn)
	}
	closed := make([]*Connection, 0, limit)
	for index := len(c.history) - 1; index >= 0 && len(closed) < limit; index-- {
		conn := c.history[index]
		if conn.Revision.Load() > after {
			closed = append(closed, conn)
		}
	}
	out = append(out, closed...)
	c.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		return out[i].StartedAt.After(out[j].StartedAt)
	})
	return out, cursor
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
