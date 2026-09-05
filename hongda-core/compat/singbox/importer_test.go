package singbox

import (
	"strings"
	"testing"
)

func TestImportPreservesTunOptions(t *testing.T) {
	cfg, err := Import(map[string]interface{}{
		"inbounds": []interface{}{map[string]interface{}{
			"type": "tun", "tag": "tun-in", "interface_name": "HongdaTun",
			"address": []interface{}{"172.19.0.1/30"}, "mtu": float64(1400),
			"auto_route": true, "strict_route": true, "stack": "mixed",
			"route_address": []interface{}{"0.0.0.0/1", "128.0.0.0/1"},
		}},
		"outbounds": []interface{}{map[string]interface{}{
			"type": "direct", "tag": "direct",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Inbounds) != 1 {
		t.Fatalf("inbounds = %#v", cfg.Inbounds)
	}
	in := cfg.Inbounds[0]
	if in.TUNInterface != "HongdaTun" || in.TUNMTU != 1400 || !in.TUNAutoRoute || !in.TUNStrictRoute || in.TUNStack != "mixed" {
		t.Fatalf("TUN options = %#v", in)
	}
	if len(in.TUNAddress) != 1 || len(in.TUNRouteAddr) != 2 {
		t.Fatalf("TUN addresses = %#v routes = %#v", in.TUNAddress, in.TUNRouteAddr)
	}
}

func TestImportPreservesRemoteRuleSets(t *testing.T) {
	cfg, err := Import(map[string]interface{}{
		"inbounds": []interface{}{map[string]interface{}{
			"type": "mixed", "tag": "mixed-in", "listen_port": float64(7890),
		}},
		"outbounds": []interface{}{map[string]interface{}{
			"type": "direct", "tag": "direct",
		}},
		"route": map[string]interface{}{
			"rule_set": []interface{}{map[string]interface{}{
				"type": "remote", "tag": "cn", "format": "binary", "url": "https://example.com/cn.srs",
				"download_detour": "direct", "update_interval": "1d",
			}},
			"rules": []interface{}{map[string]interface{}{
				"rule_set": []interface{}{"cn"}, "action": "route", "outbound": "direct",
			}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Rulesets) != 1 || cfg.Rulesets[0].ID != "cn" || cfg.Rulesets[0].UpdateInterval != 86400 {
		t.Fatalf("rule sets = %#v", cfg.Rulesets)
	}
	if len(cfg.Rules) != 1 || len(cfg.Rules[0].Match.RuleSet) != 1 || cfg.Rules[0].Match.RuleSet[0] != "cn" {
		t.Fatalf("rules = %#v", cfg.Rules)
	}
}

func TestImportPreservesDoHDetourAndTLSName(t *testing.T) {
	cfg, err := Import(map[string]interface{}{
		"dns": map[string]interface{}{"strategy": "ipv4_only", "servers": []interface{}{map[string]interface{}{
			"type": "https", "tag": "remote", "server": "1.1.1.1", "path": "/dns-query", "detour": "proxy",
			"tls": map[string]interface{}{"server_name": "cloudflare-dns.com"},
		}}},
		"inbounds": []interface{}{map[string]interface{}{
			"type": "mixed", "tag": "mixed-in", "listen_port": float64(7890),
		}},
		"outbounds": []interface{}{
			map[string]interface{}{"type": "direct", "tag": "node"},
			map[string]interface{}{"type": "selector", "tag": "proxy", "outbounds": []interface{}{"node"}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if cfg.DNS.Server != "https://1.1.1.1/dns-query" || cfg.DNS.TLSServer != "cloudflare-dns.com" || cfg.DNS.Detour != "proxy" || cfg.DNS.Strategy != "ipv4_only" {
		t.Fatalf("DNS options = %#v", cfg.DNS)
	}
}

func TestImportRejectsUnsupportedEndpoints(t *testing.T) {
	_, err := Import(map[string]interface{}{
		"endpoints": []interface{}{map[string]interface{}{"type": "tailscale", "tag": "tailscale"}},
	})
	if err == nil {
		t.Fatal("expected unsupported endpoint error")
	}
}

func TestImportDoesNotTreatFalseIPIsPrivateAsMatcher(t *testing.T) {
	cfg, err := Import(map[string]interface{}{
		"inbounds": []interface{}{map[string]interface{}{
			"type": "mixed", "tag": "mixed-in", "listen_port": float64(7890),
		}},
		"outbounds": []interface{}{map[string]interface{}{
			"type": "direct", "tag": "direct",
		}},
		"route": map[string]interface{}{"rules": []interface{}{map[string]interface{}{
			"ip_is_private": false, "action": "route", "outbound": "direct",
		}}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.Rules) != 1 || len(cfg.Rules[0].Match.IPCIDR) != 0 {
		t.Fatalf("rules = %#v", cfg.Rules)
	}
}

func TestImportRejectsUnsupportedProtocolSemantics(t *testing.T) {
	tests := []struct {
		name     string
		outbound map[string]interface{}
		want     string
	}{
		{
			name: "unknown protocol",
			outbound: map[string]interface{}{
				"type": "vmess", "tag": "node", "server": "example.com", "server_port": float64(443),
			},
			want: "protocol \"vmess\" is not implemented",
		},
		{
			name: "hysteria obfs",
			outbound: map[string]interface{}{
				"type": "hysteria2", "tag": "node", "server": "example.com", "server_port": float64(443), "password": "secret",
				"obfs": map[string]interface{}{"type": "salamander", "password": "obfs-secret"},
			},
			want: "hysteria2 obfs",
		},
		{
			name: "http transport",
			outbound: map[string]interface{}{
				"type": "vless", "tag": "node", "server": "example.com", "server_port": float64(443), "uuid": "00000000-0000-0000-0000-000000000001",
				"transport": map[string]interface{}{"type": "http"},
			},
			want: "HTTP transport is not implemented",
		},
		{
			name: "multiplex",
			outbound: map[string]interface{}{
				"type": "trojan", "tag": "node", "server": "example.com", "server_port": float64(443), "password": "secret",
				"multiplex": map[string]interface{}{"enabled": true},
			},
			want: "multiplex is not implemented",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Import(map[string]interface{}{
				"inbounds":  []interface{}{map[string]interface{}{"type": "mixed", "tag": "mixed-in", "listen_port": float64(7890)}},
				"outbounds": []interface{}{test.outbound},
			})
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
		})
	}
}
