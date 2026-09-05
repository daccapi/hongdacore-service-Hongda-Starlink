package singbox

import (
	"strings"
	"testing"
)

func TestImportRejectsTunInsteadOfSilentlyIgnoringIt(t *testing.T) {
	_, err := Import(map[string]interface{}{
		"inbounds": []interface{}{map[string]interface{}{
			"type": "tun", "tag": "tun-in",
		}},
		"outbounds": []interface{}{map[string]interface{}{
			"type": "direct", "tag": "direct",
		}},
	})
	if err == nil || !strings.Contains(err.Error(), "TUN is not implemented") {
		t.Fatalf("error = %v", err)
	}
}

func TestImportRejectsRemoteRuleSets(t *testing.T) {
	_, err := Import(map[string]interface{}{
		"inbounds": []interface{}{map[string]interface{}{
			"type": "mixed", "tag": "mixed-in", "listen_port": float64(7890),
		}},
		"outbounds": []interface{}{map[string]interface{}{
			"type": "direct", "tag": "direct",
		}},
		"route": map[string]interface{}{
			"rule_set": []interface{}{map[string]interface{}{"tag": "cn"}},
		},
	})
	if err == nil || !strings.Contains(err.Error(), "refusing to ignore 1 rule sets") {
		t.Fatalf("error = %v", err)
	}
}

func TestImportPreservesDoHDetourAndTLSName(t *testing.T) {
	cfg, err := Import(map[string]interface{}{
		"dns": map[string]interface{}{"servers": []interface{}{map[string]interface{}{
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
	if cfg.DNS.Server != "https://1.1.1.1/dns-query" || cfg.DNS.TLSServer != "cloudflare-dns.com" || cfg.DNS.Detour != "proxy" {
		t.Fatalf("DNS options = %#v", cfg.DNS)
	}
}
