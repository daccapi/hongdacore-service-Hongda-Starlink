package route

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/protocol"
	"hongda.local/hongda-core/telemetry"
)

// No public endpoint or real proxy is used: the DNS server counts redundant
// requests, and each outbound records a destination without opening a socket.
type performanceOutbound struct {
	*protocol.Direct
	address string
}

func (o *performanceOutbound) DialContext(_ context.Context, _, address string) (net.Conn, error) {
	o.address = address
	a, b := net.Pipe()
	b.Close()
	return a, nil
}

func TestSniffedDestinationDoesNotResolveAgain(t *testing.T) {
	var queries atomic.Int32
	dns := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		queries.Add(1)
		wire, _ := io.ReadAll(r.Body)
		wire[2] |= 0x80
		w.Write(wire)
	}))
	defer dns.Close()
	for _, tc := range []struct{ name, address, want string }{
		{"video", "203.0.113.8:443", "proxy"},
		{"private IP retains priority", "10.0.0.8:443", "direct"},
		{"IPv6 guard retains priority", "[2001:db8::8]:443", "reject"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
			defer r.Close()
			proxy := &performanceOutbound{Direct: protocol.NewDirect("proxy")}
			direct := &performanceOutbound{Direct: protocol.NewDirect("direct")}
			r.Register(proxy)
			r.Register(direct)
			r.Register(protocol.NewDirect("dns"))
			r.SetPolicy([]model.Rule{
				{Match: model.MatchExpr{IPCIDR: []string{"private"}}, Action: model.ActionRoute, Target: "direct"},
				{Match: model.MatchExpr{IPCIDR: []string{"::/0"}}, Action: model.ActionReject},
				{Match: model.MatchExpr{DomainSuffix: []string{"googlevideo.com"}}, Action: model.ActionRoute, Target: "proxy"},
			}, model.DNSOptions{Mode: "doh", Server: dns.URL, Strategy: "ipv4_only", Detour: "dns"})
			c, err := r.DialWithDomain("tcp", tc.address, "r1.example.googlevideo.com")
			if c != nil {
				defer c.Close()
			}
			if tc.want == "reject" {
				if err == nil {
					t.Error("IPv6 destination bypassed reject rule")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				if c.(*routedConnection).route != tc.want {
					t.Errorf("route=%s want %s", c.(*routedConnection).route, tc.want)
				}
				if c.(*routedConnection).destination != tc.address {
					t.Error("destination changed")
				}
				if c.(*routedConnection).domain != "r1.example.googlevideo.com" {
					t.Error("sniffed domain missing from connection log")
				}
			}
		})
	}
	if got := queries.Load(); got != 0 {
		t.Fatalf("known destination IP caused %d unnecessary DNS requests", got)
	}
}

func TestHostnameOnlyStillUsesDNSForIPRules(t *testing.T) {
	var queries atomic.Int32
	dns := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		queries.Add(1)
		wire, _ := io.ReadAll(r.Body)
		wire[2] |= 0x80
		w.Write(wire)
	}))
	defer dns.Close()
	r := New("proxy", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	r.Register(protocol.NewDirect("dns"))
	r.SetPolicy([]model.Rule{{Match: model.MatchExpr{IPCIDR: []string{"private"}}, Target: "direct"}},
		model.DNSOptions{Mode: "doh", Server: dns.URL, Detour: "dns", Strategy: "ipv4_only"})
	if _, err := r.routeTarget(context.Background(), "tcp", "domain.example:443"); err != nil {
		t.Fatal(err)
	}
	if queries.Load() == 0 {
		t.Fatal("hostname-only IP rule resolution was bypassed")
	}
}

type brokenReadConn struct{ net.Conn }

func (c *brokenReadConn) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }

func TestPipeReadErrorReleasesBothDirections(t *testing.T) {
	client, app := net.Pipe()
	upstream, server := net.Pipe()
	defer app.Close()
	defer server.Close()
	defer client.Close()
	defer upstream.Close()
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	done := make(chan struct{})
	go func() { r.Pipe(&brokenReadConn{client}, upstream); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("failed stream left reverse copy and connection alive")
	}
	if len(r.conns.Snapshot()) != 0 {
		t.Fatal("failed connection still tracked")
	}
}
