package probe

import (
	"context"
	"hongda.local/hongda-core/protocol"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestProbeGlobalConcurrencyBound(t *testing.T) {
	var active, peak atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := active.Add(1)
		defer active.Add(-1)
		for p := peak.Load(); n > p; p = peak.Load() {
			if peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(15 * time.Millisecond)
		w.WriteHeader(204)
	}))
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var wg sync.WaitGroup
	for range 24 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := Measure(ctx, protocol.NewDirect("node"), server.URL); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if p := peak.Load(); p > Concurrency || p < 2 {
		t.Fatalf("unexpected parallelism %d", p)
	}
}

func TestProbeRejectsFailuresAndDoesNotFollowRedirects(t *testing.T) {
	var redirected atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/target" {
			redirected.Store(true)
			w.WriteHeader(204)
			return
		}
		if r.URL.Path == "/redirect" {
			http.Redirect(w, r, "/target", 302)
			return
		}
		w.WriteHeader(503)
	}))
	defer server.Close()
	for _, path := range []string{"/error", "/redirect"} {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		_, err := Measure(ctx, protocol.NewDirect("node"), server.URL+path)
		cancel()
		if err == nil {
			t.Fatalf("%s marked healthy", path)
		}
	}
	if redirected.Load() {
		t.Fatal("followed redirect")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Measure(ctx, protocol.NewDirect("node"), server.URL); err == nil {
		t.Fatal("ignored cancellation")
	}
}
