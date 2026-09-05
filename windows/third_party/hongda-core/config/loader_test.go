package config

import (
	"testing"

	"hongda.local/hongda-core/model"
)

func tunConfig(final string) *model.Config {
	return &model.Config{
		DNS: model.DNSOptions{Mode: "doh", Server: "https://1.1.1.1/dns-query", Detour: "node"},
		Inbounds: []model.InboundConfig{{
			Type: "tun", Tag: "tun-in", TUNAutoRoute: true, TUNAddress: []string{"172.19.0.1/30"},
		}},
		Nodes: []model.Node{{
			ID: "node", Type: model.ProtocolVLESS, Server: "example.com", Port: 443,
			Auth: map[string]string{"uuid": "00000000-0000-0000-0000-000000000001"},
		}},
		Route: model.RouteConfig{Final: final},
		API:   model.APIConfig{Listen: "127.0.0.1:9090"},
	}
}

func TestValidateAcceptsSafeAutoRouteTUN(t *testing.T) {
	cfg := tunConfig("node")
	cfg.Rules = []model.Rule{{
		Action: model.ActionRoute,
		Target: "direct",
		Match:  model.MatchExpr{IPCIDR: []string{"private", "127.0.0.0/8"}},
	}}
	if err := Validate(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestValidateAcceptsDirectAutoRouteWithInterfaceBinding(t *testing.T) {
	cfg := tunConfig("direct")
	if err := Validate(cfg); err != nil {
		t.Fatal(err)
	}
}

func TestValidateAcceptsSelectorThatCanBecomeDirect(t *testing.T) {
	cfg := tunConfig("proxy")
	cfg.Groups = []model.GroupConfig{{
		ID: "proxy", Type: "select", Members: []string{"node", "direct"}, Default: "node",
	}}
	if err := Validate(cfg); err != nil {
		t.Fatal(err)
	}
}
