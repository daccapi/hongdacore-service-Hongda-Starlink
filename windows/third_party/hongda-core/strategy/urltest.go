package strategy

import (
	"context"
	"net/url"
	"sort"
	"strings"
	"time"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/probe"
)

// URLTest selects a healthy member by end-to-end URL response time.
type URLTest struct {
	*base
	target    string
	tolerance time.Duration
}

type urlTestResult struct {
	name    string
	latency time.Duration
	err     error
}

func NewURLTest(id string, members map[string]model.Outbound, target string, toleranceMillis int) *URLTest {
	if toleranceMillis < 0 {
		toleranceMillis = 0
	}
	u := &URLTest{
		base:      newBase(id, "urltest"),
		target:    target,
		tolerance: time.Duration(toleranceMillis) * time.Millisecond,
	}
	for _, name := range orderedNames(members) {
		u.addMember(name, members[name])
	}
	return u
}

func (u *URLTest) Refresh(ctx context.Context) error {
	results := make(chan urlTestResult, len(u.members))
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
	// A fixed worker pool also bounds goroutines for large subscriptions.
	jobs := make(chan string)
	workers := min(len(u.members), probe.Concurrency)
	for range workers {
		go func() {
			for name := range jobs {
				result, err := probe.Measure(ctx, u.members[name], parsed.String())
				results <- urlTestResult{name: name, latency: result.Total, err: err}
			}
		}()
	}
	go func() {
		defer close(jobs)
		for _, name := range orderedNames(u.members) {
			jobs <- name
		}
	}()
	collected := make([]urlTestResult, 0, len(u.members))
	for range u.members {
		collected = append(collected, <-results)
	}
	sort.SliceStable(collected, func(i, j int) bool {
		return collected[i].err == nil && (collected[j].err != nil || collected[i].latency < collected[j].latency)
	})
	u.mu.RLock()
	current := u.current
	u.mu.RUnlock()
	selected, ready := chooseURLTestCurrent(current, u.tolerance, collected)
	if ready {
		u.mu.Lock()
		u.current = selected
		u.health = model.GroupHealth{Ready: true}
		u.mu.Unlock()
		return nil
	}
	u.mu.Lock()
	u.health = model.GroupHealth{Ready: false, LastError: "all members failed"}
	u.mu.Unlock()
	return context.DeadlineExceeded
}

func chooseURLTestCurrent(current string, tolerance time.Duration, collected []urlTestResult) (string, bool) {
	if len(collected) == 0 || collected[0].err != nil {
		return current, false
	}
	best := collected[0]
	for _, candidate := range collected {
		if candidate.name != current || candidate.err != nil {
			continue
		}
		// Preserve a healthy current member unless the best alternative is
		// faster by more than the configured tolerance. This prevents periodic
		// tests from moving existing traffic because of normal latency jitter.
		if candidate.latency <= best.latency+tolerance {
			return current, true
		}
		break
	}
	return best.name, true
}

var _ model.Group = (*URLTest)(nil)

type errInvalidTestURL struct{}

func (errInvalidTestURL) Error() string { return "invalid URL test target" }
