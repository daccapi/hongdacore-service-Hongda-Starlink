// Package core owns the runtime lifecycle: it compiles a model.Config into
// outbounds, groups, router, inbound and API, then starts/stops them.
package core

import (
	"context"
	"fmt"
	"net"
	"sync"
	"time"

	"hongda.local/hongda-core/api"
	"hongda.local/hongda-core/inbound"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/protocol"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/ruleset"
	"hongda.local/hongda-core/strategy"
	"hongda.local/hongda-core/telemetry"
	"hongda.local/hongda-core/tunnel"
)

type Runtime struct {
	config        *model.Config
	traffic       *telemetry.Traffic
	conns         *telemetry.Connections
	router        *route.Router
	inbounds      []*inbound.Mixed
	tunnels       []tunnel.Manager
	api           *api.Controller
	outbounds     map[string]model.Outbound
	refreshCancel context.CancelFunc
	refreshWG     sync.WaitGroup
	prepareMu     sync.Mutex
	prepared      bool
}

func NewRuntime(cfg *model.Config) *Runtime {
	return &Runtime{
		config:    cfg,
		traffic:   &telemetry.Traffic{},
		conns:     telemetry.NewConnections(),
		outbounds: make(map[string]model.Outbound),
	}
}

func (r *Runtime) Traffic() *telemetry.Traffic          { return r.traffic }
func (r *Runtime) Connections() *telemetry.Connections  { return r.conns }
func (r *Runtime) Router() *route.Router                { return r.router }
func (r *Runtime) Outbounds() map[string]model.Outbound { return r.outbounds }

// Build compiles the unified config into runtime objects. It does not start
// any listener yet.
func (r *Runtime) Build() error {
	for _, in := range r.config.Inbounds {
		if in.Type == "tun" && !tunnel.Supported() {
			return fmt.Errorf("TUN is unavailable in this build; use the Windows with_gvisor release")
		}
	}
	// 1. Protocol outbounds from nodes.
	for _, node := range r.config.Nodes {
		ob, err := protocol.NewOutbound(node)
		if err != nil {
			return fmt.Errorf("build node %q: %w", node.ID, err)
		}
		r.outbounds[ob.ID()] = ob
	}

	// 2. A direct outbound is always available, including to groups that list
	// it as a member.
	if _, ok := r.outbounds["direct"]; !ok {
		r.outbounds["direct"] = protocol.NewDirect("direct")
	}

	// 3. Strategy groups. Resolve them in passes so a selector may reference a
	// group declared later in the config without silently dropping that member.
	pending := append([]model.GroupConfig(nil), r.config.Groups...)
	for len(pending) > 0 {
		remaining := make([]model.GroupConfig, 0, len(pending))
		builtThisPass := 0
		for _, gc := range pending {
			members := make(map[string]model.Outbound)
			for _, name := range gc.Members {
				if ob, ok := r.outbounds[name]; ok {
					members[name] = ob
				}
			}
			if len(members) != len(gc.Members) {
				remaining = append(remaining, gc)
				continue
			}
			var group model.Group
			switch gc.Type {
			case "urltest", "url-test":
				group = strategy.NewURLTest(gc.ID, members, gc.URL, gc.Tolerance)
			case "select", "selector":
				group = strategy.NewSelect(gc.ID, members, gc.Default)
			default:
				group = strategy.NewSelect(gc.ID, members, gc.Default)
			}
			r.outbounds[group.ID()] = group
			builtThisPass++
		}
		if builtThisPass == 0 {
			ids := make([]string, 0, len(remaining))
			for _, gc := range remaining {
				ids = append(ids, gc.ID)
			}
			return fmt.Errorf("unresolved or cyclic strategy groups: %v", ids)
		}
		pending = remaining
	}

	// 4. Router.
	r.router = route.New(r.config.Route.Final, r.traffic, r.conns)
	r.router.EnableDNSPersistence(r.config.Core.CacheDir)
	r.router.SetPolicy(r.config.Rules, r.config.DNS)
	for _, ob := range r.outbounds {
		r.router.Register(ob)
	}
	return nil
}

// PrepareRuleSets downloads or validates cached remote sets before any local
// listener or TUN route is started. A failed first download therefore cannot
// leave Windows in a half-connected state.
func (r *Runtime) PrepareRuleSets(ctx context.Context) error {
	r.prepareMu.Lock()
	defer r.prepareMu.Unlock()
	if r.prepared {
		return nil
	}
	if r.router == nil {
		return fmt.Errorf("runtime is not built")
	}
	loaded := make(map[string]*ruleset.Set, len(r.config.Rulesets))
	type loadResult struct {
		id  string
		set *ruleset.Set
		err error
	}
	prepareContext, cancel := context.WithCancel(ctx)
	defer cancel()
	results := make(chan loadResult, len(r.config.Rulesets))
	// A single VLESS/REALITY node can become unstable when five first-run rule
	// set downloads open simultaneously. Two workers retain parallelism without
	// overwhelming the selected outbound or a rate-limited CDN.
	downloadSlots := make(chan struct{}, 2)
	for _, setConfig := range r.config.Rulesets {
		setConfig := setConfig
		go func() {
			select {
			case downloadSlots <- struct{}{}:
				defer func() { <-downloadSlots }()
			case <-prepareContext.Done():
				results <- loadResult{id: setConfig.ID, err: prepareContext.Err()}
				return
			}
			var dialContext ruleset.DialContext
			if setConfig.DownloadDetour != "" {
				detour := setConfig.DownloadDetour
				dialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
					return r.router.DialVia(ctx, detour, network, address)
				}
			}
			set, err := ruleset.Load(prepareContext, setConfig, r.config.Core.CacheDir, dialContext)
			results <- loadResult{id: setConfig.ID, set: set, err: err}
		}()
	}
	var firstErr error
	for range r.config.Rulesets {
		result := <-results
		if result.err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("prepare rule set %q: %w", result.id, result.err)
				cancel()
			}
			continue
		}
		loaded[result.id] = result.set
	}
	if firstErr != nil {
		return firstErr
	}
	r.router.SetRuleSets(loaded)
	r.prepared = true
	return nil
}

// Start brings up every configured proxy inbound and the API controller.
func (r *Runtime) Start() error {
	prepareContext, cancelPrepare := context.WithTimeout(context.Background(), 3*time.Minute)
	err := r.PrepareRuleSets(prepareContext)
	cancelPrepare()
	if err != nil {
		return err
	}
	for _, in := range r.config.Inbounds {
		if in.Type != "mixed" && in.Type != "socks" && in.Type != "http" {
			continue
		}
		listen := in.Listen
		if listen == "" {
			listen = "127.0.0.1"
		}
		addr := net.JoinHostPort(listen, fmt.Sprintf("%d", in.Port))
		listener := inbound.NewMixed(r.router)
		if err := listener.Start(addr); err != nil {
			for _, started := range r.inbounds {
				_ = started.Close()
			}
			r.inbounds = nil
			return err
		}
		r.inbounds = append(r.inbounds, listener)
	}
	r.api = api.NewController(r.config.API, r.router, r.traffic, r.conns)
	if err := r.api.Start(); err != nil {
		for _, started := range r.inbounds {
			_ = started.Close()
		}
		r.inbounds = nil
		return fmt.Errorf("start control API: %w", err)
	}
	for _, in := range r.config.Inbounds {
		if in.Type != "tun" {
			continue
		}
		manager, err := tunnel.New(in, r.router, r.config)
		if err != nil {
			r.closeStarted()
			return fmt.Errorf("configure TUN inbound %q: %w", in.Tag, err)
		}
		if err := manager.Start(); err != nil {
			_ = manager.Close()
			r.closeStarted()
			return fmt.Errorf("start TUN inbound %q: %w", in.Tag, err)
		}
		r.tunnels = append(r.tunnels, manager)
	}
	r.startGroupRefresh()
	return nil
}

func (r *Runtime) closeStarted() {
	for i := len(r.tunnels) - 1; i >= 0; i-- {
		_ = r.tunnels[i].Close()
	}
	r.tunnels = nil
	if r.api != nil {
		_ = r.api.Close()
		r.api = nil
	}
	for _, started := range r.inbounds {
		_ = started.Close()
	}
	r.inbounds = nil
}

func (r *Runtime) startGroupRefresh() {
	ctx, cancel := context.WithCancel(context.Background())
	r.refreshCancel = cancel
	for _, groupConfig := range r.config.Groups {
		if groupConfig.Type != "urltest" && groupConfig.Type != "url-test" {
			continue
		}
		group, ok := r.outbounds[groupConfig.ID].(model.Group)
		if !ok {
			continue
		}
		interval := time.Duration(groupConfig.Interval) * time.Second
		if interval < 10*time.Second {
			interval = 5 * time.Minute
		}
		r.refreshWG.Add(1)
		go func(group model.Group, interval time.Duration) {
			defer r.refreshWG.Done()
			refresh := func() {
				probeCtx, probeCancel := context.WithTimeout(ctx, 15*time.Second)
				defer probeCancel()
				_ = group.Refresh(probeCtx)
			}
			refresh()
			ticker := time.NewTicker(interval)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					refresh()
				}
			}
		}(group, interval)
	}
}

// Close stops the API and inbound listeners.
func (r *Runtime) Close() error {
	if r.refreshCancel != nil {
		r.refreshCancel()
		r.refreshWG.Wait()
		r.refreshCancel = nil
	}
	// Close TUN first so its routes and WFP filters are removed before proxy
	// sockets disappear. This prevents a transient system-wide network outage.
	r.closeStarted()
	if r.router != nil {
		r.router.Close()
	}
	for _, ob := range r.outbounds {
		_ = ob.Close()
	}
	return nil
}
