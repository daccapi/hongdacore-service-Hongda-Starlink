package route

import (
	"context"
	"encoding/binary"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/protocol"
	"hongda.local/hongda-core/strategy"
	"hongda.local/hongda-core/telemetry"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

type regressionOutbound struct {
	*protocol.Direct
	calls atomic.Int32
}

func (o *regressionOutbound) DialContext(ctx context.Context, n, a string) (net.Conn, error) {
	o.calls.Add(1)
	return o.Direct.DialContext(ctx, n, a)
}

func TestRegressionDNSSwitchUsesNewNodeEvenAfterPoolCloses(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, q *http.Request) {
		wire, _ := io.ReadAll(q.Body)
		wire[2] |= 0x80
		w.Header().Set("Connection", "close")
		w.Write(wire)
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
	if _, err := r.ExchangeDNS(context.Background(), buildDNSQuery("first.example", 1)); err != nil {
		t.Fatal(err)
	}
	selector.SetCurrent("b")
	if _, err := r.ExchangeDNS(context.Background(), buildDNSQuery("second.example", 1)); err != nil {
		t.Fatal(err)
	}
	if b.calls.Load() != 1 {
		t.Fatalf("after switch: old node dial count=%d, new node=%d; DNS still pins old node", a.calls.Load(), b.calls.Load())
	}
}

func TestRegressionDNSMustNotExtendShortTTL(t *testing.T) {
	for _, ttl := range []uint32{0, 1, 5} {
		response := buildDNSQuery("short.example", 1)
		response[2] |= 0x80
		binary.BigEndian.PutUint16(response[6:8], 1)
		response = append(response, 0xc0, 0x0c, 0, 1, 0, 1)
		response = binary.BigEndian.AppendUint32(response, ttl)
		response = append(response, 0, 4, 192, 0, 2, 1)
		if got := dnsResponseCacheTTL(response); got > time.Duration(ttl)*time.Second {
			t.Errorf("upstream TTL=%ds cached for %v", ttl, got)
		}
	}
}

type regressionDirectRecorder struct {
	*protocol.Direct
	destination string
}

func (o *regressionDirectRecorder) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	if host, _, _ := net.SplitHostPort(address); host == "127.0.0.1" {
		return o.Direct.DialContext(ctx, network, address)
	}
	o.destination = address
	a, b := net.Pipe()
	_ = b.Close()
	return a, nil
}
func TestRegressionDoHFailureMustNotFallbackToSystemDNS(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { http.Error(w, "unavailable", 503) }))
	defer srv.Close()
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	direct := &regressionDirectRecorder{Direct: protocol.NewDirect("direct")}
	r.Register(direct)
	r.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: srv.URL})
	conn, err := r.Dial("tcp", "example.invalid:443")
	if conn != nil {
		defer conn.Close()
	}
	if err == nil {
		t.Fatalf("DoH failed but unresolved hostname passed to system direct dialer: %s", direct.destination)
	}
}
