// Package core owns the runtime lifecycle: it compiles a model.Config into
// outbounds, groups, router, inbound and API, then starts/stops them.
package core

import (
	"fmt"
	"net"

	"hongda.local/hongda-core/api"
	"hongda.local/hongda-core/inbound"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/protocol"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/strategy"
	"hongda.local/hongda-core/telemetry"
)

type Runtime struct {
	config    *model.Config
	traffic   *telemetry.Traffic
	conns     *telemetry.Connections
	router    *route.Router
	inbound   *inbound.Mixed
	api       *api.Controller
	outbounds map[string]model.Outbound
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
	// 1. Protocol outbounds from nodes.
	for _, node := range r.config.Nodes {
		ob, err := protocol.NewOutbound(node)
		if err != nil {
			return fmt.Errorf("build node %q: %w", node.ID, err)
		}
		r.outbounds[ob.ID()] = ob
	}

	// 2. Strategy groups referencing those outbounds.
	for _, gc := range r.config.Groups {
		members := make(map[string]model.Outbound)
		for _, name := range gc.Members {
			if ob, ok := r.outbounds[name]; ok {
				members[name] = ob
			}
		}
		if len(members) == 0 {
			continue
		}
		var group model.Group
		switch gc.Type {
		case "urltest", "url-test":
			group = strategy.NewURLTest(gc.ID, members, gc.URL)
		case "select", "selector":
			group = strategy.NewSelect(gc.ID, members, gc.Default)
		default:
			group = strategy.NewSelect(gc.ID, members, gc.Default)
		}
		r.outbounds[group.ID()] = group
	}

	// 3. A direct outbound is always available.
	if _, ok := r.outbounds["direct"]; !ok {
		r.outbounds["direct"] = protocol.NewDirect("direct")
	}

	// 4. Router.
	r.router = route.New(r.config.Route.Final, r.traffic, r.conns)
	r.router.SetPolicy(r.config.Rules, r.config.DNS)
	for _, ob := range r.outbounds {
		r.router.Register(ob)
	}
	return nil
}

// Start brings up the mixed inbound and the API controller.
func (r *Runtime) Start() error {
	for _, in := range r.config.Inbounds {
		if in.Type != "mixed" {
			continue
		}
		addr := net.JoinHostPort(in.Listen, fmt.Sprintf("%d", in.Port))
		r.inbound = inbound.NewMixed(r.router)
		if err := r.inbound.Start(addr); err != nil {
			return err
		}
		break
	}
	r.api = api.NewController(r.config.API, r.router, r.traffic, r.conns)
	return r.api.Start()
}

// Close stops the API and inbound listeners.
func (r *Runtime) Close() error {
	if r.api != nil {
		_ = r.api.Close()
	}
	if r.inbound != nil {
		_ = r.inbound.Close()
	}
	for _, ob := range r.outbounds {
		_ = ob.Close()
	}
	return nil
}
