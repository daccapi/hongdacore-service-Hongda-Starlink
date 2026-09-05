package route

import (
	"context"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/ruleset"
	"hongda.local/hongda-core/telemetry"
)

func TestBuildDNSQueryName(t *testing.T) {
	q := buildDNSQuery("www.example.com", 1)
	if len(q) < 20 {
		t.Fatalf("query too short: %d", len(q))
	}
	if got := q[len(q)-4:]; binary.BigEndian.Uint16(got[:2]) != 1 || binary.BigEndian.Uint16(got[2:]) != 1 {
		t.Fatalf("bad query trailer %x", got)
	}
}

func TestExchangeDNSSuppressesAAAAForIPv4OnlyTUN(t *testing.T) {
	router := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	router.SetPolicy(nil, model.DNSOptions{
		Mode: "doh", Server: "https://invalid.example/dns-query", Strategy: "ipv4_only",
	})
	query := buildDNSQuery("www.example.com", 28)
	response, err := router.ExchangeDNS(context.Background(), query)
	if err != nil {
		t.Fatal(err)
	}
	if len(response) != len(query) || binary.BigEndian.Uint16(response[0:2]) != binary.BigEndian.Uint16(query[0:2]) {
		t.Fatalf("invalid empty response: %x", response)
	}
	if binary.BigEndian.Uint16(response[6:8]) != 0 || response[2]&0x80 == 0 {
		t.Fatalf("response is not an empty DNS answer: %x", response[:12])
	}
}

func TestExchangeDNSRejectRuleReturnsNXDOMAINWithoutUpstream(t *testing.T) {
	set, err := ruleset.ParseSource("ads", []byte(`{
		"version":3,"rules":[{"domain_suffix":["ads.example"]}]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	router := New("proxy", &telemetry.Traffic{}, telemetry.NewConnections())
	router.SetRuleSets(map[string]*ruleset.Set{"ads": set})
	router.SetPolicy([]model.Rule{
		{Match: model.MatchExpr{Port: []string{"53"}}, Action: model.ActionHijackDNS},
		{Match: model.MatchExpr{RuleSet: []string{"ads"}}, Action: model.ActionReject},
	}, model.DNSOptions{Mode: "doh", Server: "https://invalid.example/dns-query"})
	response, err := router.ExchangeDNS(context.Background(), buildDNSQuery("track.ads.example", 1))
	if err != nil {
		t.Fatal(err)
	}
	if rcode := binary.BigEndian.Uint16(response[2:4]) & 0x000f; rcode != 3 {
		t.Fatalf("rcode = %d, want NXDOMAIN", rcode)
	}
}

func TestServeDNSStreamUsesDoH(t *testing.T) {
	doh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		query, err := io.ReadAll(request.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(query)
	}))
	defer doh.Close()

	traffic := &telemetry.Traffic{}
	router := New("direct", traffic, telemetry.NewConnections())
	router.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: doh.URL})
	client, server := net.Pipe()
	_ = client.SetDeadline(time.Now().Add(5 * time.Second))
	done := make(chan error, 1)
	go func() { done <- router.ServeDNSStream(context.Background(), server) }()

	query := buildDNSQuery("example.com", 1)
	frame := binary.BigEndian.AppendUint16(nil, uint16(len(query)))
	frame = append(frame, query...)
	if _, err := client.Write(frame); err != nil {
		t.Fatal(err)
	}
	responseFrame := make([]byte, len(frame))
	if _, err := io.ReadFull(client, responseFrame); err != nil {
		t.Fatal(err)
	}
	if string(responseFrame) != string(frame) {
		t.Fatalf("response = %x, want %x", responseFrame, frame)
	}
	_ = client.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("TCP DNS stream did not stop")
	}
	if traffic.Upload() != int64(len(frame)) || traffic.Download() != int64(len(frame)) {
		t.Fatalf("traffic = up %d down %d", traffic.Upload(), traffic.Download())
	}
}

func TestParseDNSAnswersA(t *testing.T) {
	name := []byte{3, 'w', 'w', 'w', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0}
	packet := make([]byte, 12)
	binary.BigEndian.PutUint16(packet[4:6], 1)
	binary.BigEndian.PutUint16(packet[6:8], 1)
	packet = append(packet, name...)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = append(packet, 0xC0, 0x0C)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = binary.BigEndian.AppendUint32(packet, 60)
	packet = binary.BigEndian.AppendUint16(packet, 4)
	packet = append(packet, 1, 2, 3, 4)

	ips, err := parseDNSAnswers(packet, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(ips) != 1 || !ips[0].Equal(net.IP{1, 2, 3, 4}) {
		t.Fatalf("ips = %v", ips)
	}
}

func TestLookupDoHUsesConfiguredDetourDialer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Content-Type") != "application/dns-message" {
			http.Error(w, "expected RFC 8484 POST", http.StatusBadRequest)
			return
		}
		data, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		qtype := binary.BigEndian.Uint16(data[len(data)-4 : len(data)-2])
		response := append([]byte(nil), data...)
		response[2], response[3] = 0x81, 0x80
		binary.BigEndian.PutUint16(response[6:8], 1)
		response = append(response, 0xC0, 0x0C)
		response = binary.BigEndian.AppendUint16(response, qtype)
		response = binary.BigEndian.AppendUint16(response, 1)
		response = binary.BigEndian.AppendUint32(response, 60)
		if qtype == 1 {
			response = binary.BigEndian.AppendUint16(response, 4)
			response = append(response, 203, 0, 113, 10)
		} else {
			response = binary.BigEndian.AppendUint16(response, 16)
			response = append(response, net.ParseIP("2001:db8::10").To16()...)
		}
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(response)
	}))
	defer server.Close()

	dialCount := 0
	dialer := func(ctx context.Context, network, address string) (net.Conn, error) {
		dialCount++
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}
	ips, err := lookupDoH(context.Background(), model.DNSOptions{Server: server.URL}, "example.com", dialer)
	if err != nil {
		t.Fatal(err)
	}
	if dialCount != 2 {
		t.Fatalf("detour dial count = %d, want 2", dialCount)
	}
	if len(ips) != 2 {
		t.Fatalf("ips = %v", ips)
	}
}

func TestRouterCachesDoHAcrossSequentialRuleChecks(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		query, _ := io.ReadAll(request.Body)
		queryType := binary.BigEndian.Uint16(query[len(query)-4 : len(query)-2])
		response := append([]byte(nil), query...)
		response[2], response[3] = 0x81, 0x80
		binary.BigEndian.PutUint16(response[6:8], 1)
		response = append(response, 0xC0, 0x0C)
		response = binary.BigEndian.AppendUint16(response, queryType)
		response = binary.BigEndian.AppendUint16(response, 1)
		response = binary.BigEndian.AppendUint32(response, 60)
		if queryType == 1 {
			response = binary.BigEndian.AppendUint16(response, 4)
			response = append(response, 203, 0, 113, 20)
		} else {
			response = binary.BigEndian.AppendUint16(response, 16)
			response = append(response, net.ParseIP("2001:db8::20").To16()...)
		}
		_, _ = w.Write(response)
	}))
	defer server.Close()
	router := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	router.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: server.URL})
	for index := 0; index < 3; index++ {
		ips, err := router.lookupIPs(context.Background(), "cache.example")
		if err != nil || len(ips) != 2 {
			t.Fatalf("lookup %d: ips=%v err=%v", index, ips, err)
		}
	}
	if requests.Load() != 2 {
		t.Fatalf("DoH requests = %d, want one A and one AAAA request", requests.Load())
	}
}

func TestExchangeDNSCachesByQuestionAndRestoresTransactionID(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		requests.Add(1)
		query, _ := io.ReadAll(request.Body)
		response := append([]byte(nil), query...)
		response[2], response[3] = 0x81, 0x80
		binary.BigEndian.PutUint16(response[6:8], 1)
		response = append(response, 0xC0, 0x0C)
		response = binary.BigEndian.AppendUint16(response, 1)
		response = binary.BigEndian.AppendUint16(response, 1)
		response = binary.BigEndian.AppendUint32(response, 120)
		response = binary.BigEndian.AppendUint16(response, 4)
		response = append(response, 203, 0, 113, 30)
		_, _ = w.Write(response)
	}))
	defer server.Close()

	router := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	defer router.Close()
	router.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: server.URL})
	first := buildDNSQuery("cached.example", 1)
	second := append([]byte(nil), first...)
	binary.BigEndian.PutUint16(second[0:2], 0x5678)
	if _, err := router.ExchangeDNS(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	response, err := router.ExchangeDNS(context.Background(), second)
	if err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 1 {
		t.Fatalf("DoH requests = %d, want cached second query", requests.Load())
	}
	if binary.BigEndian.Uint16(response[0:2]) != 0x5678 {
		t.Fatalf("cached transaction ID = %x", response[0:2])
	}
}

func TestExchangeDNSReusesHTTPConnectionAcrossQuestions(t *testing.T) {
	var connections atomic.Int32
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		query, _ := io.ReadAll(request.Body)
		response := append([]byte(nil), query...)
		response[2], response[3] = 0x81, 0x80
		_, _ = w.Write(response)
	}))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	server.Start()
	defer server.Close()

	router := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	defer router.Close()
	router.SetPolicy(nil, model.DNSOptions{Mode: "doh", Server: server.URL})
	for _, domain := range []string{"first.example", "second.example"} {
		if _, err := router.ExchangeDNS(context.Background(), buildDNSQuery(domain, 1)); err != nil {
			t.Fatal(err)
		}
	}
	if connections.Load() != 1 {
		t.Fatalf("DoH TCP connections = %d, want one reused connection", connections.Load())
	}
}
