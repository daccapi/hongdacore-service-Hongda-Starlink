package route

import (
	"context"
	"encoding/binary"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/protocol"
	"hongda.local/hongda-core/strategy"
	"hongda.local/hongda-core/telemetry"
	"io"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

func safetyDNSAnswer(query []byte, ttl uint32) []byte {
	response := append([]byte(nil), query...)
	response[2] |= 0x80
	binary.BigEndian.PutUint16(response[6:8], 1)
	response = append(response, 0xc0, 0x0c, 0, 1, 0, 1)
	response = binary.BigEndian.AppendUint32(response, ttl)
	return append(response, 0, 4, 192, 0, 2, 1)
}

func TestDNSCompressionRejectsCyclesAndInvalidLabels(t *testing.T) {
	for _, wire := range [][]byte{{0xc0, 0}, {0xc0, 2, 0xc0, 0}, {0x40}, {0x80}, {0xc0, 127}, {63, 'a'}} {
		if _, _, err := readDNSName(wire, 0); err == nil {
			t.Fatalf("accepted malformed name %x", wire)
		}
	}
	name, next, err := readDNSName([]byte{1, 'a', 0, 0xc0, 0}, 3)
	if err != nil || name != "a" || next != 5 {
		t.Fatalf("valid compressed name %q %d %v", name, next, err)
	}
}

func TestDNSCacheAgesTTLWithoutChangingEDNSFlags(t *testing.T) {
	query := buildDNSQuery("ttl.example", 1)
	response := safetyDNSAnswer(query, 5)
	binary.BigEndian.PutUint16(response[10:12], 1)
	response = append(response, 0, 0, 41, 0x10, 0, 0, 0, 0x80, 0, 0, 0) // OPT DO bit; not a TTL.
	if ttl := dnsResponseCacheTTL(response); ttl != 5*time.Second {
		t.Fatalf("TTL with OPT = %v", ttl)
	}
	records, err := walkDNSRecords(response)
	if err != nil {
		t.Fatal(err)
	}
	aged := ageDNSResponse(response, query, 3*time.Second)
	if got := binary.BigEndian.Uint32(aged[records[0].ttlOffset:]); got != 2 {
		t.Fatalf("aged TTL %d", got)
	}
	if got := binary.BigEndian.Uint32(aged[records[1].ttlOffset:]); got != 0x8000 {
		t.Fatalf("modified EDNS flags %x", got)
	}
	if got := binary.BigEndian.Uint32(response[records[0].ttlOffset:]); got != 5 {
		t.Fatal("mutated cached response")
	}
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	r.rememberDNSResponse(query, safetyDNSAnswer(query, 0))
	if len(r.domainsForAddress(netip.MustParseAddr("192.0.2.1"))) != 0 {
		t.Fatal("TTL zero persisted in reverse cache")
	}
}

func TestDNSSelectorRefreshesKeepAliveAndCachedQuestion(t *testing.T) {
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		query, _ := io.ReadAll(request.Body)
		w.Write(safetyDNSAnswer(query, 60))
	}))
	defer srv.Close()
	a := &regressionOutbound{Direct: protocol.NewDirect("a")}
	b := &regressionOutbound{Direct: protocol.NewDirect("b")}
	selector := strategy.NewSelect("proxy", map[string]model.Outbound{"a": a, "b": b}, "a")
	r := New("proxy", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	r.Register(a)
	r.Register(b)
	r.Register(selector)
	r.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: srv.URL, Detour: "proxy"})
	query := buildDNSQuery("cached.example", 1)
	for range 2 {
		if _, err := r.ExchangeDNS(context.Background(), query); err != nil {
			t.Fatal(err)
		}
	}
	if requests.Load() != 1 {
		t.Fatal("same-node response not cached")
	}
	if !selector.SetCurrent("b") {
		t.Fatal("selector rejected member")
	}
	r.InvalidateDNSConnections()
	if _, err := r.ExchangeDNS(context.Background(), query); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 2 || b.calls.Load() != 1 {
		t.Fatalf("new selector reused old cache or connection: requests=%d new dials=%d", requests.Load(), b.calls.Load())
	}
}

func TestDNSInvalidationCancelsOutstandingDoH(t *testing.T) {
	entered := make(chan struct{})
	released := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(io.Discard, r.Body)
		close(entered)
		<-r.Context().Done()
		close(released)
	}))
	defer srv.Close()
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	r.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: srv.URL})
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	done := make(chan error, 1)
	go func() { _, err := r.ExchangeDNS(ctx, buildDNSQuery("cancel.example", 1)); done <- err }()
	<-entered
	r.InvalidateDNSConnections()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("inflight query must be cancelled")
		}
	case <-ctx.Done():
		t.Fatal("old DNS request did not stop")
	}
	select {
	case <-released:
	case <-ctx.Done():
		t.Fatal("old DNS socket still active")
	}
}
