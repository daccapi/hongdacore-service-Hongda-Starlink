package core_test

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"hongda.local/hongda-core/config"
	"hongda.local/hongda-core/core"
)

// TestLiveExistingVLESS is opt-in because it needs the user's current node and
// public network access. It deliberately removes unsupported TUN/rule-set DNS
// fields, then verifies the Hongda data plane rather than only its config
// parser. Run with HONGDA_LIVE_CONFIG pointing at the external-format JSON
// config.
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
	preferredTag := ""
	for _, item := range outbounds {
		candidate, _ := item.(map[string]any)
		if candidate["tag"] == "proxy" {
			preferredTag, _ = candidate["default"].(string)
			break
		}
	}
	var liveNode map[string]any
	for _, item := range outbounds {
		candidate, _ := item.(map[string]any)
		typ, _ := candidate["type"].(string)
		tag, _ := candidate["tag"].(string)
		if typ != "" && typ != "direct" && typ != "selector" && typ != "urltest" &&
			(preferredTag == "" || tag == preferredTag) {
			liveNode = candidate
			break
		}
	}
	if liveNode == nil {
		t.Fatal("live config has no concrete proxy node")
	}
	if os.Getenv("HONGDA_LIVE_INSECURE") == "1" {
		tlsRaw, _ := liveNode["tls"].(map[string]any)
		if tlsRaw == nil {
			t.Fatal("HONGDA_LIVE_INSECURE requested but selected node has no TLS block")
		}
		tlsRaw["insecure"] = true
		t.Log("selected proxy entry TLS verification disabled for this isolated live test")
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
	for _, targetURL := range []string{
		"https://www.gstatic.com/generate_204",
		"https://www.youtube.com/generate_204",
	} {
		directResponse, requestErr := (&http.Client{Transport: directTransport, Timeout: 25 * time.Second}).Get(targetURL)
		if requestErr != nil {
			t.Fatalf("direct HTTP probe %s through %s: %v", targetURL, cfg.Nodes[0].ID, requestErr)
		}
		_ = directResponse.Body.Close()
		if directResponse.StatusCode < 200 || directResponse.StatusCode >= 400 {
			t.Fatalf("direct HTTP probe %s status = %d", targetURL, directResponse.StatusCode)
		}
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
	logResponse, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/connection-log", apiPort))
	if err != nil {
		t.Fatalf("connection log API: %v", err)
	}
	var logPayload struct {
		Connections []map[string]any `json:"connections"`
	}
	decodeErr := json.NewDecoder(logResponse.Body).Decode(&logPayload)
	_ = logResponse.Body.Close()
	if decodeErr != nil {
		t.Fatal(decodeErr)
	}
	metadataFound := false
	for _, entry := range logPayload.Connections {
		domain, _ := entry["domain"].(string)
		outbound, _ := entry["outbound"].(string)
		if strings.Contains(domain, "gstatic.com") && outbound == nodeTag {
			metadataFound = true
			break
		}
	}
	if !metadataFound {
		t.Fatalf("connection log missing routed domain/outbound metadata: %#v", logPayload.Connections)
	}
	t.Logf("VLESS request OK; up=%d down=%d", runtime.Traffic().Upload(), runtime.Traffic().Download())
}

// TestLiveWindowsTUN is deliberately separate from the proxy-inbound test: it
// changes the Windows default route for the lifetime of the test. It refuses
// to run next to known competing TUN clients and always closes the runtime
// before returning. Run from an elevated shell with HONGDA_LIVE_TUN=1 and
// HONGDA_LIVE_CONFIG set to the current Starlink config.
func TestLiveWindowsTUN(t *testing.T) {
	if os.Getenv("HONGDA_LIVE_TUN") != "1" {
		t.Skip("HONGDA_LIVE_TUN is not enabled")
	}
	for _, networkInterface := range mustInterfaces(t) {
		if networkInterface.Flags&net.FlagUp == 0 {
			continue
		}
		name := strings.ToLower(networkInterface.Name)
		if strings.Contains(name, "karing") || strings.Contains(name, "clash") || strings.Contains(name, "v2ray") {
			t.Skipf("competing TUN interface is active: %s", networkInterface.Name)
		}
	}
	path := os.Getenv("HONGDA_LIVE_CONFIG")
	if path == "" {
		t.Fatal("HONGDA_LIVE_CONFIG is not set")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
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
	routeRaw, _ := raw["route"].(map[string]any)
	ruleSets, _ := routeRaw["rule_set"].([]any)
	if len(ruleSets) == 0 {
		t.Fatal("live config has no remote rule sets")
	}
	availableSets := make(map[string]bool, len(ruleSets))
	for _, item := range ruleSets {
		if set, ok := item.(map[string]any); ok {
			if tag, ok := set["tag"].(string); ok {
				availableSets[tag] = true
			}
		}
	}
	for _, required := range []string{"karing-lan", "karing-cn-domain", "karing-cn-ip", "karing-proxy-lite"} {
		if !availableSets[required] {
			t.Fatalf("live config is missing rule set %s", required)
		}
	}
	raw["route"] = map[string]any{
		"rule_set": ruleSets,
		"rules": []any{
			map[string]any{"port": float64(53), "action": "hijack-dns"},
			map[string]any{"rule_set": []any{"karing-lan", "karing-cn-domain"}, "action": "route", "outbound": "direct"},
			map[string]any{"rule_set": "karing-proxy-lite", "action": "route", "outbound": "proxy"},
			map[string]any{"rule_set": "karing-cn-ip", "action": "route", "outbound": "direct"},
		},
		"final": "proxy",
	}
	raw["inbounds"] = []any{map[string]any{
		"type": "tun", "tag": "tun-live", "interface_name": "HongdaTun",
		"address": []any{"172.29.8.1/30"}, "mtu": float64(1500),
		"auto_route": true, "strict_route": true, "stack": "gvisor",
		"route_address": []any{"0.0.0.0/1", "128.0.0.0/1"},
	}}
	raw["experimental"] = map[string]any{"clash_api": map[string]any{
		"external_controller": fmt.Sprintf("127.0.0.1:%d", freePort(t)), "secret": "",
	}}
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
	// Reuse the exact cache validated by HongdaService doctor. The TUN test is
	// intended to validate Windows routing/DNS, not make its result depend on a
	// transient CDN response after the user has deliberately disabled the
	// competing TUN.
	cfg.Core.CacheDir = filepath.Join(filepath.Dir(path), "rulesets")
	runtime := core.NewRuntime(cfg)
	if err := runtime.Build(); err != nil {
		t.Fatal(err)
	}
	if err := runtime.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := runtime.Close(); err != nil {
			t.Errorf("restore TUN routes: %v", err)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if addresses, err := net.DefaultResolver.LookupHost(ctx, "www.gstatic.com"); err != nil || len(addresses) == 0 {
		t.Fatalf("TUN encrypted DNS lookup failed: addresses=%v error=%v", addresses, err)
	}
	if err := liveDNSQuery("udp", "1.1.1.1:53"); err != nil {
		t.Fatalf("TUN UDP/53 -> DoH interception failed: %v", err)
	}
	if err := liveDNSQuery("tcp", "1.1.1.1:53"); err != nil {
		t.Fatalf("TUN TCP/53 -> DoH interception failed: %v", err)
	}
	client := &http.Client{
		Timeout: 25 * time.Second,
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
		},
	}
	response, err := client.Get("https://www.gstatic.com/generate_204")
	if err != nil {
		t.Fatalf("system HTTP through TUN: %v", err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("TUN HTTP status = %d", response.StatusCode)
	}
	directResponse, err := client.Get("https://www.baidu.com/")
	if err != nil {
		t.Fatalf("China direct rule through physical interface: %v", err)
	}
	_, _ = io.CopyN(io.Discard, directResponse.Body, 1)
	_ = directResponse.Body.Close()
	if directResponse.StatusCode < 200 || directResponse.StatusCode >= 500 {
		t.Fatalf("China direct probe status = %d", directResponse.StatusCode)
	}
	if runtime.Traffic().Upload() == 0 || runtime.Traffic().Download() == 0 {
		t.Fatalf("TUN counters did not advance: up=%d down=%d", runtime.Traffic().Upload(), runtime.Traffic().Download())
	}
	t.Logf("Windows TUN proxy/direct/DNS checks OK; up=%d down=%d", runtime.Traffic().Upload(), runtime.Traffic().Download())
}

func liveDNSQuery(network, address string) error {
	query := make([]byte, 12)
	binary.BigEndian.PutUint16(query[0:2], 0x4844)
	binary.BigEndian.PutUint16(query[2:4], 0x0100)
	binary.BigEndian.PutUint16(query[4:6], 1)
	for _, label := range strings.Split("www.gstatic.com", ".") {
		query = append(query, byte(len(label)))
		query = append(query, label...)
	}
	query = append(query, 0, 0, 1, 0, 1)
	conn, err := net.DialTimeout(network, address, 8*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(12 * time.Second))
	if network == "tcp" {
		frame := binary.BigEndian.AppendUint16(nil, uint16(len(query)))
		frame = append(frame, query...)
		if _, err := conn.Write(frame); err != nil {
			return err
		}
		var length [2]byte
		if _, err := io.ReadFull(conn, length[:]); err != nil {
			return err
		}
		response := make([]byte, int(binary.BigEndian.Uint16(length[:])))
		if _, err := io.ReadFull(conn, response); err != nil {
			return err
		}
		if len(response) < 12 || binary.BigEndian.Uint16(response[:2]) != 0x4844 {
			return fmt.Errorf("invalid TCP DNS response")
		}
		return nil
	}
	if _, err := conn.Write(query); err != nil {
		return err
	}
	response := make([]byte, 64*1024)
	n, err := conn.Read(response)
	if err != nil {
		return err
	}
	if n < 12 || binary.BigEndian.Uint16(response[:2]) != 0x4844 {
		return fmt.Errorf("invalid UDP DNS response")
	}
	return nil
}

func mustInterfaces(t *testing.T) []net.Interface {
	t.Helper()
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal(err)
	}
	return interfaces
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
