package route

import (
	"context"
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
