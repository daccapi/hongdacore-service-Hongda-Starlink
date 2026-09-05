package route

import (
	"context"
	"testing"

	"hongda.local/hongda-core/model"
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
