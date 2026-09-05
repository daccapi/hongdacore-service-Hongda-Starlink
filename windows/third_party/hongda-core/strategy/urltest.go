package strategy

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strings"
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
	target := strings.TrimSpace(u.target)
	if target == "" {
		target = "https://www.gstatic.com/generate_204"
	} else if !strings.Contains(target, "://") {
		target = "https://" + target
	}
	parsed, err := url.Parse(target)
	if err != nil || parsed.Hostname() == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return &url.Error{Op: "parse", URL: target, Err: errInvalidTestURL{}}
	}
	for name, ob := range u.members {
		go func(name string, ob model.Outbound) {
			transport := &http.Transport{
				Proxy:             nil,
				DisableKeepAlives: true,
				DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
					return ob.DialContext(ctx, network, address)
				},
			}
			defer transport.CloseIdleConnections()
			request, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
			if err != nil {
				results <- result{name: name, err: err}
				return
			}
			start := time.Now()
			response, err := (&http.Client{Transport: transport}).Do(request)
			if err != nil {
				results <- result{name: name, err: err}
				return
			}
			_, _ = io.CopyN(io.Discard, response.Body, 1)
			_ = response.Body.Close()
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

type errInvalidTestURL struct{}

func (errInvalidTestURL) Error() string { return "invalid URL test target" }
