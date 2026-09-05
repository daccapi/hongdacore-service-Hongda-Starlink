// Package api exposes the Hongda control plane. The HTTP surface is Clash
// compatible enough for the existing Flutter UI, but it is owned by Hongda
// rather than being a copy of any upstream controller.
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/telemetry"
)

const coreVersion = "1.8.0"

type Controller struct {
	config       model.APIConfig
	router       *route.Router
	stats        *telemetry.Traffic
	connRegistry *telemetry.Connections
	server       *http.Server
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
	mux.HandleFunc("/traffic", c.traffic)

	c.server = &http.Server{Addr: c.config.Listen, Handler: mux}
	go func() {
		_ = c.server.ListenAndServe()
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
	writeJSON(w, map[string]any{"version": coreVersion})
}

func (c *Controller) proxies(w http.ResponseWriter, r *http.Request) {
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
		writeJSON(w, map[string]any{"error": "missing proxy name"})
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
		writeJSON(w, map[string]any{"error": "proxy not found"})
		return
	}
	if r.Method == http.MethodPut {
		var body struct {
			Name string `json:"name"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.Name == "" {
			writeJSON(w, map[string]any{"error": "invalid body"})
			return
		}
		if s, ok := ob.(interface{ SetCurrent(string) bool }); ok {
			s.SetCurrent(body.Name)
		}
	}
	if g, ok := ob.(model.Group); ok {
		writeJSON(w, groupView(g))
		return
	}
	writeJSON(w, map[string]any{"type": string(ob.Type())})
}

func (c *Controller) proxyDelay(w http.ResponseWriter, r *http.Request, name string) {
	ob, ok := c.router.Outbounds()[name]
	if !ok {
		writeJSON(w, map[string]any{"delay": 0})
		return
	}
	target := r.URL.Query().Get("url")
	if target == "" {
		target = "https://www.gstatic.com/generate_204"
	}
	u, err := url.Parse(target)
	if err != nil || u.Hostname() == "" {
		writeJSON(w, map[string]any{"delay": 0})
		return
	}
	port := u.Port()
	if port == "" {
		if u.Scheme == "https" {
			port = "443"
		} else {
			port = "80"
		}
	}
	p, _ := strconv.Atoi(port)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	start := time.Now()
	conn, err := ob.DialContext(ctx, "tcp", net.JoinHostPort(u.Hostname(), strconv.Itoa(p)))
	if err != nil {
		writeJSON(w, map[string]any{"delay": 0, "error": err.Error()})
		return
	}
	_ = conn.Close()
	writeJSON(w, map[string]any{"delay": time.Since(start).Milliseconds()})
}

func (c *Controller) connections(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodDelete {
		c.connRegistry.CloseAll()
		w.WriteHeader(http.StatusNoContent)
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

func (c *Controller) traffic(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeJSON(w, map[string]any{"up": 0, "down": 0})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	lastUp, lastDown := c.stats.Upload(), c.stats.Download()
	for {
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
			up, down := c.stats.Upload(), c.stats.Download()
			payload, _ := json.Marshal(map[string]any{"up": up - lastUp, "down": down - lastDown})
			if _, err := w.Write(append(payload, '\n')); err != nil {
				return
			}
			flusher.Flush()
			lastUp, lastDown = up, down
		}
	}
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

var _ = fmt.Sprintf
