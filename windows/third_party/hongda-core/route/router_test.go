package route

import (
	"context"
	"encoding/binary"
	"net/netip"
	"testing"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/ruleset"
	"hongda.local/hongda-core/telemetry"
)

func TestRouteTargetDomainRules(t *testing.T) {
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetPolicy([]model.Rule{
		{Match: model.MatchExpr{DomainSuffix: []string{"google.com"}}, Action: model.ActionRoute, Target: "proxy"},
		{Match: model.MatchExpr{Network: "udp"}, Action: model.ActionRoute, Target: "udp-out"},
	}, model.DNSOptions{Mode: "local"})

	target, err := r.routeTarget(context.Background(), "tcp", "www.google.com:443")
	if err != nil {
		t.Fatal(err)
	}
	if target != "proxy" {
		t.Fatalf("target = %q, want proxy", target)
	}

	target, err = r.routeTarget(context.Background(), "udp", "1.1.1.1:53")
	if err != nil {
		t.Fatal(err)
	}
	if target != "udp-out" {
		t.Fatalf("target = %q, want udp-out", target)
	}
}

func TestDestinationMatchersUseORSemantics(t *testing.T) {
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetPolicy([]model.Rule{{
		Match: model.MatchExpr{
			DomainSuffix: []string{"google.com"},
			IPCIDR:       []string{"10.0.0.0/8"},
		},
		Action: model.ActionRoute,
		Target: "proxy",
	}}, model.DNSOptions{Mode: "local"})

	target, err := r.routeTarget(context.Background(), "tcp", "www.google.com:443")
	if err != nil {
		t.Fatal(err)
	}
	if target != "proxy" {
		t.Fatalf("target = %q, want proxy", target)
	}
}

func TestRuleSetMatchesDomainAndIP(t *testing.T) {
	set, err := ruleset.ParseSource("sample", []byte(`{
		"version": 3,
		"rules": [{"domain_suffix":["example.com"],"ip_cidr":["203.0.113.0/24"]}]
	}`))
	if err != nil {
		t.Fatal(err)
	}
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetRuleSets(map[string]*ruleset.Set{"sample": set})
	r.SetPolicy([]model.Rule{{
		Match:  model.MatchExpr{RuleSet: []string{"sample"}},
		Action: model.ActionRoute,
		Target: "proxy",
	}}, model.DNSOptions{Mode: "local"})

	for _, address := range []string{"www.example.com:443", "203.0.113.8:443"} {
		target, routeErr := r.routeTarget(context.Background(), "tcp", address)
		if routeErr != nil {
			t.Fatal(routeErr)
		}
		if target != "proxy" {
			t.Fatalf("address %s target = %q, want proxy", address, target)
		}
	}
}

func TestRouteReject(t *testing.T) {
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetPolicy([]model.Rule{
		{Match: model.MatchExpr{IPCIDR: []string{"10.0.0.0/8"}}, Action: model.ActionReject},
	}, model.DNSOptions{Mode: "local"})

	_, err := r.routeTarget(context.Background(), "tcp", "10.1.2.3:80")
	if err == nil {
		t.Fatal("expected reject error")
	}
}

func TestTUNDestinationUsesInterceptedDNSDomain(t *testing.T) {
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetPolicy([]model.Rule{{
		Match:  model.MatchExpr{DomainSuffix: []string{"youtube.com", "googlevideo.com"}},
		Action: model.ActionRoute,
		Target: "proxy",
	}}, model.DNSOptions{Mode: "doh"})

	query := buildDNSQuery("www.youtube.com", 1)
	response := append([]byte(nil), query...)
	binary.BigEndian.PutUint16(response[2:4], 0x8180)
	binary.BigEndian.PutUint16(response[6:8], 1)
	response = append(response, 0xc0, 0x0c, 0x00, 0x01, 0x00, 0x01)
	response = binary.BigEndian.AppendUint32(response, 120)
	response = binary.BigEndian.AppendUint16(response, 4)
	response = append(response, 203, 0, 113, 42)
	r.rememberDNSResponse(query, response)

	target, err := r.routeTarget(context.Background(), "tcp", "203.0.113.42:443")
	if err != nil {
		t.Fatal(err)
	}
	if target != "proxy" {
		t.Fatalf("target = %q, want proxy for intercepted YouTube address", target)
	}
}

func TestTUNIPv6DestinationUsesInterceptedDNSDomain(t *testing.T) {
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetPolicy([]model.Rule{{
		Match:  model.MatchExpr{DomainSuffix: []string{"google.com"}},
		Action: model.ActionRoute,
		Target: "proxy",
	}}, model.DNSOptions{Mode: "doh"})

	query := buildDNSQuery("www.google.com", 28)
	response := append([]byte(nil), query...)
	binary.BigEndian.PutUint16(response[2:4], 0x8180)
	binary.BigEndian.PutUint16(response[6:8], 1)
	response = append(response, 0xc0, 0x0c, 0x00, 0x1c, 0x00, 0x01)
	response = binary.BigEndian.AppendUint32(response, 120)
	response = binary.BigEndian.AppendUint16(response, 16)
	address := netip.MustParseAddr("2001:db8::42").As16()
	response = append(response, address[:]...)
	r.rememberDNSResponse(query, response)

	target, err := r.routeTarget(context.Background(), "tcp", "[2001:db8::42]:443")
	if err != nil {
		t.Fatal(err)
	}
	if target != "proxy" {
		t.Fatalf("target = %q, want proxy for intercepted Google IPv6 address", target)
	}
}

func TestRejectQUICOnly(t *testing.T) {
	r := New("direct", &telemetry.Traffic{}, telemetry.NewConnections())
	r.SetPolicy([]model.Rule{{
		Match:  model.MatchExpr{Network: "udp", Port: []string{"443"}},
		Action: model.ActionReject,
	}}, model.DNSOptions{Mode: "local"})

	if _, err := r.routeTarget(context.Background(), "udp", "203.0.113.9:443"); err == nil {
		t.Fatal("expected UDP/443 to be rejected")
	}
	target, err := r.routeTarget(context.Background(), "tcp", "203.0.113.9:443")
	if err != nil {
		t.Fatal(err)
	}
	if target != "direct" {
		t.Fatalf("TCP/443 target = %q, want direct", target)
	}
}
