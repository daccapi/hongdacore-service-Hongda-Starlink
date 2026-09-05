// Package api exposes the Hongda control plane. The HTTP surface is Clash
// compatible enough for the existing Flutter UI, but it is owned by Hongda
// rather than being a copy of any upstream controller.
package api

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/websocket"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/telemetry"
)

const coreVersion = "1.10.0"

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
	mux.HandleFunc("/connections", c.connections)
	mux.Handle("/traffic", websocket.Handler(c.trafficWebSocket))

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
	transport := &http.Transport{
		Proxy:             nil,
		DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			return ob.DialContext(ctx, network, address)
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
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
	writeJSON(w, map[string]any{
		"delay":  time.Since(start).Milliseconds(),
		"status": response.StatusCode,
	})
}

func (c *Controller) connections(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		c.connRegistry.CloseAll()
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	items := c.connRegistry.Snapshot()
	conns := make([]map[string]any, 0, len(items))
	for _, it := range items {
		conns = append(conns, map[string]any{
			"id":          it.ID,
			"network":     it.Network,
			"host":        it.Host,
			"destination": it.Destination,
			"upload":      it.Upload.Load(),
			"download":    it.Download.Load(),
		})
	}
	writeJSON(w, map[string]any{
		"uploadTotal":   c.stats.Upload(),
		"downloadTotal": c.stats.Download(),
		"connections":   conns,
	})
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
