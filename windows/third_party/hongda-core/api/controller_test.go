package api

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"testing"
	"time"

	"golang.org/x/net/websocket"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/telemetry"
)

func TestTrafficIsClashCompatibleWebSocket(t *testing.T) {
	stats := &telemetry.Traffic{}
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0"}, stats)
	defer controller.Close()

	address := controller.listener.Addr().String()
	ws, err := websocket.Dial("ws://"+address+"/traffic", "", "http://"+address)
	if err != nil {
		t.Fatalf("dial traffic websocket: %v", err)
	}
	defer ws.Close()
	// Allow the handler to capture its initial cumulative counters before the
	// test adds a new one-second sample.
	time.Sleep(100 * time.Millisecond)
	stats.AddUpload(321)
	stats.AddDownload(654)
	_ = ws.SetDeadline(time.Now().Add(3 * time.Second))
	var payload string
	if err := websocket.Message.Receive(ws, &payload); err != nil {
		t.Fatalf("receive traffic frame: %v", err)
	}
	var frame map[string]int64
	if err := json.Unmarshal([]byte(payload), &frame); err != nil {
		t.Fatalf("decode traffic frame %q: %v", payload, err)
	}
	if frame["up"] != 321 || frame["down"] != 654 {
		t.Fatalf("traffic frame = %#v", frame)
	}
}

func TestTrafficWebSocketAcceptsNativeClientWithoutOrigin(t *testing.T) {
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0"}, &telemetry.Traffic{})
	defer controller.Close()
	address := controller.listener.Addr().String()
	conn, err := net.Dial("tcp", address)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	request := "GET /traffic HTTP/1.1\r\n" +
		"Host: " + address + "\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: websocket\r\n" +
		"Sec-WebSocket-Version: 13\r\n" +
		"Sec-WebSocket-Key: SG9uZ2RhU3RhcmxpbmsxOA==\r\n\r\n"
	if _, err := io.WriteString(conn, request); err != nil {
		t.Fatal(err)
	}
	response, err := http.ReadResponse(bufio.NewReader(conn), &http.Request{Method: http.MethodGet})
	if err != nil {
		t.Fatalf("read native websocket handshake: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("native websocket status = %d", response.StatusCode)
	}
}

func TestTrafficWebSocketRejectsNonLoopbackBrowserOrigin(t *testing.T) {
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0"}, &telemetry.Traffic{})
	defer controller.Close()
	address := controller.listener.Addr().String()
	ws, err := websocket.Dial("ws://"+address+"/traffic", "", "https://example.com")
	if err == nil {
		_ = ws.Close()
		t.Fatal("expected non-loopback browser origin to be rejected")
	}
}

func TestConnectionsWebSocketStreamsSnapshot(t *testing.T) {
	stats := &telemetry.Traffic{}
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0"}, stats)
	defer controller.Close()
	connection := controller.connRegistry.AddDetailed(telemetry.ConnectionMetadata{
		Network: "tcp", Source: "172.19.0.1:52000", Host: "104.18.32.47",
		Destination: "104.18.32.47:443", Domain: "chatgpt.com",
		Route: "proxy", Outbound: "node-test", Rule: "规则 1 · 域名",
	}, func() {})
	connection.Upload.Add(123)
	connection.Download.Add(456)
	stats.AddUpload(123)
	stats.AddDownload(456)

	address := controller.listener.Addr().String()
	ws, err := websocket.Dial("ws://"+address+"/connections", "", "http://"+address)
	if err != nil {
		t.Fatalf("dial connections websocket: %v", err)
	}
	defer ws.Close()
	_ = ws.SetDeadline(time.Now().Add(3 * time.Second))
	var payload string
	if err := websocket.Message.Receive(ws, &payload); err != nil {
		t.Fatalf("receive connections frame: %v", err)
	}
	var frame struct {
		UploadTotal   int64            `json:"uploadTotal"`
		DownloadTotal int64            `json:"downloadTotal"`
		Connections   []map[string]any `json:"connections"`
	}
	if err := json.Unmarshal([]byte(payload), &frame); err != nil {
		t.Fatalf("decode connections frame %q: %v", payload, err)
	}
	if frame.UploadTotal != 123 || frame.DownloadTotal != 456 || len(frame.Connections) != 1 {
		t.Fatalf("connections frame = %#v", frame)
	}
	if frame.Connections[0]["domain"] != "chatgpt.com" || frame.Connections[0]["outbound"] != "node-test" {
		t.Fatalf("connection metadata = %#v", frame.Connections[0])
	}
}

func TestControllerRequiresBearerSecret(t *testing.T) {
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0", Secret: "secret-value"}, &telemetry.Traffic{})
	defer controller.Close()
	url := "http://" + controller.listener.Addr().String() + "/version"

	response, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status without token = %d", response.StatusCode)
	}

	request, _ := http.NewRequest(http.MethodGet, url, nil)
	request.Header.Set("Authorization", "Bearer secret-value")
	response, err = http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status with token = %d", response.StatusCode)
	}
}

func TestTrafficWebSocketAcceptsClashTokenQuery(t *testing.T) {
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0", Secret: "secret-value"}, &telemetry.Traffic{})
	defer controller.Close()
	address := controller.listener.Addr().String()
	ws, err := websocket.Dial("ws://"+address+"/traffic?token=secret-value", "", "http://"+address)
	if err != nil {
		t.Fatalf("dial authenticated traffic websocket: %v", err)
	}
	_ = ws.Close()
}

func TestControllerReportsOccupiedPort(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	controller := NewController(
		model.APIConfig{Listen: listener.Addr().String()},
		route.New("direct", &telemetry.Traffic{}, telemetry.NewConnections()),
		&telemetry.Traffic{},
		telemetry.NewConnections(),
	)
	if err := controller.Start(); err == nil {
		_ = controller.Close()
		t.Fatal("expected occupied API port to fail")
	}
}

func TestConnectionsDeleteReturnsBeforeSlowSocketClose(t *testing.T) {
	connections := telemetry.NewConnections()
	closeStarted := make(chan struct{})
	allowClose := make(chan struct{})
	defer close(allowClose)
	connections.Add("udp", "example.com", "example.com:443", func() {
		close(closeStarted)
		<-allowClose
	})
	stats := &telemetry.Traffic{}
	controller := NewController(
		model.APIConfig{Listen: "127.0.0.1:0"},
		route.New("direct", stats, connections),
		stats,
		connections,
	)
	if err := controller.Start(); err != nil {
		t.Fatal(err)
	}
	defer controller.Close()

	request, err := http.NewRequest(
		http.MethodDelete,
		"http://"+controller.listener.Addr().String()+"/connections",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 500 * time.Millisecond}
	response, err := client.Do(request)
	if err != nil {
		t.Fatalf("DELETE /connections waited for socket close: %v", err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("status = %d", response.StatusCode)
	}
	select {
	case <-closeStarted:
	case <-time.After(time.Second):
		t.Fatal("background socket close did not start")
	}
}

func TestConnectionLogIncludesMetadataAndClosedHistory(t *testing.T) {
	stats := &telemetry.Traffic{}
	controller := newTestController(t, model.APIConfig{Listen: "127.0.0.1:0"}, stats)
	defer controller.Close()
	connection := controller.connRegistry.AddDetailed(telemetry.ConnectionMetadata{
		Network: "tcp", Source: "172.19.0.2:51000", Host: "142.250.72.14",
		Destination: "142.250.72.14:443", Domain: "www.youtube.com",
		Route: "proxy", Outbound: "node-test", Rule: "规则 5 · 域名",
	}, func() {})
	connection.Upload.Add(1234)
	connection.Download.Add(5678)
	controller.connRegistry.Remove(connection.ID)

	response, err := http.Get("http://" + controller.listener.Addr().String() + "/connection-log")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var payload struct {
		Connections []map[string]any `json:"connections"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if len(payload.Connections) != 1 {
		t.Fatalf("connection log count = %d", len(payload.Connections))
	}
	entry := payload.Connections[0]
	if entry["domain"] != "www.youtube.com" || entry["outbound"] != "node-test" || entry["status"] != "closed" {
		t.Fatalf("unexpected connection entry: %#v", entry)
	}
	if entry["startedAt"] == "" || entry["closedAt"] == "" {
		t.Fatalf("timestamps missing: %#v", entry)
	}
}

func newTestController(t *testing.T, cfg model.APIConfig, stats *telemetry.Traffic) *Controller {
	t.Helper()
	connections := telemetry.NewConnections()
	router := route.New("direct", stats, connections)
	controller := NewController(cfg, router, stats, connections)
	if err := controller.Start(); err != nil {
		t.Fatalf("start controller: %v", err)
	}
	return controller
}
