// Package api exposes the Hongda control plane. The HTTP surface follows the
// de-facto standard control-plane API the existing Flutter UI expects, but it
// is owned and implemented by Hongda.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/net/websocket"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/telemetry"
)

const coreVersion = "1.10.10"

type Controller struct {
	config       model.APIConfig
	router       *route.Router
	stats        *telemetry.Traffic
	connRegistry *telemetry.Connections
	server       *http.Server
	listener     net.Listener
}

func NewController(cfg model.APIConfig, router *route.Router, traffic *telemetry.Traffic, conns *telemetry.Connections) *Controller {
	return &Controller{config: cfg, router: router, stats: traffic, connRegistry: conns}
}

func (c *Controller) Start() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/version", c.version)
	mux.HandleFunc("/proxies", c.proxies)
	mux.HandleFunc("/proxies/", c.proxy)
	mux.HandleFunc("/connections", c.connectionsEndpoint)
	mux.HandleFunc("/connection-log", c.connectionLog)
	mux.Handle("/traffic", c.webSocketHandler(c.trafficWebSocket))

	var handler http.Handler = mux
	if c.config.Secret != "" {
		handler = c.authorize(handler)
	}
	listener, err := net.Listen("tcp", c.config.Listen)
	if err != nil {
		return err
	}
	c.listener = listener
	c.server = &http.Server{Addr: c.config.Listen, Handler: handler}
	go func() {
		if err := c.server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			_ = listener.Close()
		}
	}()
	return nil
}

func (c *Controller) Close() error {
	if c.server == nil {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return c.server.Shutdown(ctx)
}

func (c *Controller) version(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, map[string]any{"version": coreVersion})
}

func (c *Controller) proxies(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	groups := map[string]any{}
	for name, ob := range c.router.Outbounds() {
		if g, ok := ob.(model.Group); ok {
			groups[name] = groupView(g)
		}
	}
	writeJSON(w, map[string]any{"proxies": groups})
}

func (c *Controller) proxy(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/proxies/")
	if name == "" {
		writeError(w, http.StatusBadRequest, "missing proxy name")
		return
	}
	if i := strings.IndexByte(name, '/'); i >= 0 {
		suffix := name[i+1:]
		name = name[:i]
		if suffix == "delay" {
			c.proxyDelay(w, r, name)
			return
		}
	}
	ob, ok := c.router.Outbounds()[name]
	if !ok {
		writeError(w, http.StatusNotFound, "proxy not found")
		return
	}
	if r.Method == http.MethodPut {
		var body struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
			writeError(w, http.StatusBadRequest, "invalid body")
			return
		}
		s, selectable := ob.(interface{ SetCurrent(string) bool })
		if !selectable {
			writeError(w, http.StatusBadRequest, "proxy is not selectable")
			return
		}
		if !s.SetCurrent(body.Name) {
			writeError(w, http.StatusBadRequest, "selector member not found")
			return
		}
	} else if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if g, ok := ob.(model.Group); ok {
		writeJSON(w, groupView(g))
		return
	}
	writeJSON(w, map[string]any{"type": string(ob.Type())})
}

func (c *Controller) proxyDelay(w http.ResponseWriter, r *http.Request, name string) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ob, ok := c.router.Outbounds()[name]
	if !ok {
		writeError(w, http.StatusNotFound, "proxy not found")
		return
	}
	target := r.URL.Query().Get("url")
	if target == "" {
		target = "https://www.gstatic.com/generate_204"
	}
	u, err := url.Parse(target)
	if err != nil || u.Hostname() == "" || (u.Scheme != "http" && u.Scheme != "https") {
		writeError(w, http.StatusBadRequest, "invalid delay test URL")
		return
	}
	timeout := 8 * time.Second
	if raw := r.URL.Query().Get("timeout"); raw != "" {
		if millis, parseErr := strconv.Atoi(raw); parseErr == nil {
			if millis < 100 {
				millis = 100
			}
			if millis > 30000 {
				millis = 30000
			}
			timeout = time.Duration(millis) * time.Millisecond
		}
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()
	var connectDelayMillis atomic.Int64
	transport := &http.Transport{
		Proxy:             nil,
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			connectStart := time.Now()
			conn, dialErr := ob.DialContext(ctx, network, address)
			connectDelayMillis.Store(time.Since(connectStart).Milliseconds())
			return conn, dialErr
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, u.String(), nil)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid delay test request")
		return
	}
	request.Header.Set("User-Agent", "HongdaCore/"+coreVersion)
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, err.Error())
		return
	}
	_, _ = io.CopyN(io.Discard, response.Body, 1)
	_ = response.Body.Close()
	totalDelayMillis := time.Since(start).Milliseconds()
	connectDelay := connectDelayMillis.Load()
	if connectDelay <= 0 || connectDelay > totalDelayMillis {
		connectDelay = totalDelayMillis
	}
	writeJSON(w, map[string]any{
		// delay remains the Clash-compatible end-to-end URLTest value. The
		// additional fields let Hongda UI distinguish proxy transport setup from
		// destination TLS/HTTP response time instead of labelling the sum as node
		// RTT.
		"delay":        totalDelayMillis,
		"totalDelay":   totalDelayMillis,
		"connectDelay": connectDelay,
		"status":       response.StatusCode,
	})
}

func (c *Controller) connections(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		// A TUN UDP close callback can briefly wait for its packet loop. The
		// control request must not block behind that shutdown: selectors need a
		// prompt acknowledgement before they verify the new outbound. Socket
		// close still runs against the real registry entries in the background.
		go c.connRegistry.CloseAll()
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, c.connectionSnapshot())
}

func (c *Controller) connectionsEndpoint(w http.ResponseWriter, r *http.Request) {
	if strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		c.webSocketHandler(c.connectionsWebSocket).ServeHTTP(w, r)
		return
	}
	c.connections(w, r)
}

// webSocketHandler accepts native desktop clients that do not send an Origin
// header. The stock x/net/websocket handler rejects those handshakes with 403,
// which made Flutter silently fall back to HTTP polling. The controller only
// listens on loopback; browser origins are still restricted to loopback or the
// exact request host to avoid exposing a secret-less local API to arbitrary
// web pages.
func (c *Controller) webSocketHandler(handler websocket.Handler) http.Handler {
	return websocket.Server{
		Handler: handler,
		Handshake: func(config *websocket.Config, request *http.Request) error {
			origin, err := websocket.Origin(config, request)
			if err != nil {
				return err
			}
			if origin == nil {
				return nil
			}
			originHost := strings.ToLower(strings.TrimSpace(origin.Hostname()))
			requestHost := request.Host
			if host, _, splitErr := net.SplitHostPort(requestHost); splitErr == nil {
				requestHost = host
			}
			requestHost = strings.ToLower(strings.Trim(requestHost, "[]"))
			if originHost != requestHost && originHost != "localhost" {
				address := net.ParseIP(originHost)
				if address == nil || !address.IsLoopback() {
					return fmt.Errorf("websocket origin %q is not allowed", origin.String())
				}
			}
			config.Origin = origin
			return nil
		},
	}
}

func (c *Controller) connectionSnapshot() map[string]any {
	items := c.connRegistry.Snapshot()
	connections := make([]map[string]any, 0, len(items))
	for _, item := range items {
		connections = append(connections, connectionView(item))
	}
	return map[string]any{
		"uploadTotal":   c.stats.Upload(),
		"downloadTotal": c.stats.Download(),
		"connections":   connections,
	}
}

func (c *Controller) connectionLog(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		c.connRegistry.ClearHistory()
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	after := uint64(0)
	if raw := strings.TrimSpace(r.URL.Query().Get("after")); raw != "" {
		parsed, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid connection log cursor")
			return
		}
		after = parsed
	}
	limit := 1000
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			writeError(w, http.StatusBadRequest, "invalid connection log limit")
			return
		}
		limit = parsed
	}
	items, cursor := c.connRegistry.HistorySnapshotSince(after, limit)
	connections := make([]map[string]any, 0, len(items))
	for _, item := range items {
		connections = append(connections, connectionView(item))
	}
	writeJSON(w, map[string]any{"cursor": cursor, "connections": connections})
}

func connectionView(connection *telemetry.Connection) map[string]any {
	view := map[string]any{
		"id":          connection.ID,
		"network":     connection.Network,
		"source":      connection.Source,
		"host":        connection.Host,
		"destination": connection.Destination,
		"domain":      connection.Domain,
		"route":       connection.Route,
		"outbound":    connection.Outbound,
		"rule":        connection.Rule,
		"startedAt":   connection.StartedAt.Format(time.RFC3339Nano),
		"status":      "active",
		"upload":      connection.Upload.Load(),
		"download":    connection.Download.Load(),
	}
	closedAt := connection.ClosedAt()
	if !closedAt.IsZero() {
		view["status"] = "closed"
		view["closedAt"] = closedAt.Format(time.RFC3339Nano)
	}
	return view
}

// connectionsWebSocket provides Clash-compatible active connection snapshots
// without forcing desktop clients to issue two HTTP requests every second.
// The first frame is immediate so dashboards do not briefly display zero.
func (c *Controller) connectionsWebSocket(ws *websocket.Conn) {
	defer ws.Close()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		payload, _ := json.Marshal(c.connectionSnapshot())
		if err := websocket.Message.Send(ws, string(payload)); err != nil {
			return
		}
		<-ticker.C
	}
}

func (c *Controller) trafficWebSocket(ws *websocket.Conn) {
	defer ws.Close()
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	lastUp, lastDown := c.stats.Upload(), c.stats.Download()
	for {
		<-ticker.C
		up, down := c.stats.Upload(), c.stats.Download()
		payload, _ := json.Marshal(map[string]any{
			"up":   max64(0, up-lastUp),
			"down": max64(0, down-lastDown),
		})
		if err := websocket.Message.Send(ws, string(payload)); err != nil {
			return
		}
		lastUp, lastDown = up, down
	}
}

func (c *Controller) authorize(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expectedHeader := "Bearer " + c.config.Secret
		providedHeader := r.Header.Get("Authorization")
		providedToken := r.URL.Query().Get("token")
		headerOK := len(providedHeader) == len(expectedHeader) &&
			subtle.ConstantTimeCompare([]byte(providedHeader), []byte(expectedHeader)) == 1
		tokenOK := len(providedToken) == len(c.config.Secret) &&
			subtle.ConstantTimeCompare([]byte(providedToken), []byte(c.config.Secret)) == 1
		if !headerOK && !tokenOK {
			writeError(w, http.StatusUnauthorized, "unauthorized")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func groupView(g model.Group) map[string]any {
	return map[string]any{
		"type": g.Type(),
		"now":  g.Current(),
		"all":  g.Members(),
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": message})
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
