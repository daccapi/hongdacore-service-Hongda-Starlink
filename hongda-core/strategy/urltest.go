package strategy

import (
	"context"
	"net"
	"sort"
	"time"

	"hongda.local/hongda-core/model"
)

// URLTest selects the member with the lowest TCP latency.
type URLTest struct {
	*base
	target string
}

func NewURLTest(id string, members map[string]model.Outbound, target string) *URLTest {
	u := &URLTest{base: newBase(id, "urltest"), target: target}
	for _, name := range orderedNames(members) {
		u.addMember(name, members[name])
	}
	return u
}

func (u *URLTest) Refresh(ctx context.Context) error {
	type result struct {
		name    string
		latency time.Duration
		err     error
	}
	results := make(chan result, len(u.members))
	host, port, ok := splitHostPort(u.target)
	if !ok {
		host, port = "www.gstatic.com", "443"
	}
	for name, ob := range u.members {
		go func(name string, ob model.Outbound) {
			start := time.Now()
			conn, err := ob.DialContext(ctx, "tcp", net.JoinHostPort(host, port))
			if err != nil {
				results <- result{name: name, err: err}
				return
			}
			_ = conn.Close()
			results <- result{name: name, latency: time.Since(start)}
		}(name, ob)
	}
	collected := make([]result, 0, len(u.members))
	for range u.members {
		collected = append(collected, <-results)
	}
	sort.SliceStable(collected, func(i, j int) bool {
		return collected[i].err == nil && (collected[j].err != nil || collected[i].latency < collected[j].latency)
	})
	if len(collected) > 0 && collected[0].err == nil {
		u.mu.Lock()
		u.current = collected[0].name
		u.health = model.GroupHealth{Ready: true}
		u.mu.Unlock()
		return nil
	}
	u.mu.Lock()
	u.health = model.GroupHealth{Ready: false, LastError: "all members failed"}
	u.mu.Unlock()
	return context.DeadlineExceeded
}

var _ model.Group = (*URLTest)(nil)

func splitHostPort(s string) (string, string, bool) {
	u := s
	host, port, err := net.SplitHostPort(s)
	if err == nil {
		return host, port, true
	}
	_ = u
	return "", "", false
}
