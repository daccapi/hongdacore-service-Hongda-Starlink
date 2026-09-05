package core_test

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"testing"
	"time"

	"hongda.local/hongda-core/config"
	"hongda.local/hongda-core/core"
)

// TestLiveExistingVLESS is opt-in because it needs the user's current node and
// public network access. It deliberately removes unsupported TUN/rule-set DNS
// fields, then verifies the Hongda data plane rather than only its config
// parser. Run with HONGDA_LIVE_CONFIG pointing at a sing-box JSON config.
func TestLiveExistingVLESS(t *testing.T) {
	path := os.Getenv("HONGDA_LIVE_CONFIG")
	if path == "" {
		t.Skip("HONGDA_LIVE_CONFIG is not set")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	proxyPort := freePort(t)
	apiPort := freePort(t)
	raw["inbounds"] = []any{map[string]any{
		"type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": proxyPort,
	}}
	delete(raw, "dns")
	raw["route"] = map[string]any{"final": "proxy"}
	raw["experimental"] = map[string]any{"clash_api": map[string]any{
		"external_controller": fmt.Sprintf("127.0.0.1:%d", apiPort), "secret": "",
	}}
	outbounds, _ := raw["outbounds"].([]any)
	var liveNode map[string]any
	for _, item := range outbounds {
		candidate, _ := item.(map[string]any)
		typ, _ := candidate["type"].(string)
		if typ != "" && typ != "direct" && typ != "selector" && typ != "urltest" {
			liveNode = candidate
			break
		}
	}
	if liveNode == nil {
		t.Fatal("live config has no concrete proxy node")
	}
	nodeTag, _ := liveNode["tag"].(string)
	raw["outbounds"] = []any{
		liveNode,
		map[string]any{"type": "selector", "tag": "proxy", "outbounds": []any{nodeTag}, "default": nodeTag},
		map[string]any{"type": "direct", "tag": "direct"},
	}
	compatible, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.FromBytes(compatible)
	if err != nil {
		t.Fatal(err)
	}
	if err := config.Validate(cfg); err != nil {
		t.Fatal(err)
	}
	runtime := core.NewRuntime(cfg)
	if err := runtime.Build(); err != nil {
		t.Fatal(err)
	}
	if err := runtime.Start(); err != nil {
		t.Fatal(err)
	}
	defer runtime.Close()
	if len(cfg.Nodes) == 0 {
		t.Fatal("live config has no nodes")
	}
	outbound := runtime.Outbounds()[cfg.Nodes[0].ID]
	directTransport := &http.Transport{
		Proxy:             nil,
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return outbound.DialContext(ctx, network, address)
		},
	}
	directResponse, err := (&http.Client{Transport: directTransport, Timeout: 25 * time.Second}).Get("https://www.gstatic.com/generate_204")
	if err != nil {
		t.Fatalf("direct HTTP probe through %s: %v", cfg.Nodes[0].ID, err)
	}
	_ = directResponse.Body.Close()
	if directResponse.StatusCode != http.StatusNoContent {
		t.Fatalf("direct HTTP probe status = %d", directResponse.StatusCode)
	}
	for _, scheme := range []string{"http", "socks5"} {
		proxyURL, _ := url.Parse(fmt.Sprintf("%s://127.0.0.1:%d", scheme, proxyPort))
		client := &http.Client{
			Timeout: 25 * time.Second,
			Transport: &http.Transport{
				Proxy:             http.ProxyURL(proxyURL),
				DisableKeepAlives: true,
			},
		}
		request, _ := http.NewRequest(http.MethodGet, "https://www.gstatic.com/generate_204", nil)
		response, err := client.Do(request)
		if err != nil {
			t.Fatalf("request through Hongda VLESS %s proxy: %v (up=%d down=%d active=%d)", scheme, err, runtime.Traffic().Upload(), runtime.Traffic().Download(), len(runtime.Connections().Snapshot()))
		}
		_, _ = io.Copy(io.Discard, response.Body)
		_ = response.Body.Close()
		if response.StatusCode != http.StatusNoContent {
			t.Fatalf("gstatic status via %s = %d", scheme, response.StatusCode)
		}
	}
	if runtime.Traffic().Upload() == 0 || runtime.Traffic().Download() == 0 {
		t.Fatalf("live counters did not advance: up=%d down=%d", runtime.Traffic().Upload(), runtime.Traffic().Download())
	}
	t.Logf("VLESS request OK; up=%d down=%d", runtime.Traffic().Upload(), runtime.Traffic().Download())
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	return port
}
