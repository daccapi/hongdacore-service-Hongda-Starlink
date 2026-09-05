// Package config loads Hongda runtime configurations from disk and validates
// them. It is the single entry point used by both the `check` and `run` CLI
// commands. Supported import formats are detected automatically:
//
//   - External JSON (top-level "outbounds" + "inbounds", the format the
//     Flutter UI emits) — converted via compat/singbox so the existing
//     Flutter UI keeps working unchanged.
//   - Hongda native JSON ("nodes"/"groups"/"rules" top-level) — decoded
//     directly into model.Config.
//
// YAML import is planned for a later phase.
package config

import (
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"hongda.local/hongda-core/compat/singbox"
	"hongda.local/hongda-core/model"
)

// Load reads, imports and validates a configuration file. The returned Config
// is ready for the runtime to compile into outbounds/groups/router.
func Load(path string) (*model.Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	cfg, err := FromBytes(data)
	if err != nil {
		return nil, fmt.Errorf("load config %s: %w", path, err)
	}
	if cfg.Core.CacheDir == "" {
		cfg.Core.CacheDir = filepath.Join(filepath.Dir(path), "rulesets")
	}
	if err := Validate(cfg); err != nil {
		return nil, fmt.Errorf("validate config %s: %w", path, err)
	}
	return cfg, nil
}

// FromBytes detects the input format and converts it into the unified Config.
func FromBytes(data []byte) (*model.Config, error) {
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("decode config: %w", err)
	}

	_, hasOutbounds := raw["outbounds"]
	_, hasInbounds := raw["inbounds"]
	if hasOutbounds && hasInbounds {
		return singbox.Import(raw)
	}

	var cfg model.Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("decode hongda config: %w", err)
	}
	return &cfg, nil
}

// Validate performs basic structural checks shared by check and run.
func Validate(cfg *model.Config) error {
	if len(cfg.Inbounds) == 0 {
		return fmt.Errorf("at least one inbound is required")
	}
	if cfg.Core.TUN {
		return fmt.Errorf("core.tun is deprecated; configure a tun inbound")
	}
	activeInbound := false
	inboundAddresses := make(map[string]struct{})
	for _, inbound := range cfg.Inbounds {
		switch inbound.Type {
		case "mixed", "socks", "http":
			activeInbound = true
			if inbound.Port == 0 {
				return fmt.Errorf("inbound %q: port must be between 1 and 65535", inbound.Tag)
			}
			listen := inbound.Listen
			if listen == "" {
				listen = "127.0.0.1"
			}
			address := net.JoinHostPort(listen, fmt.Sprintf("%d", inbound.Port))
			if _, duplicate := inboundAddresses[address]; duplicate {
				return fmt.Errorf("duplicate inbound listen address %s", address)
			}
			inboundAddresses[address] = struct{}{}
		case "tun":
			activeInbound = true
			if inbound.TUNMTU < 0 || inbound.TUNMTU > 65535 {
				return fmt.Errorf("inbound %q: invalid TUN MTU %d", inbound.Tag, inbound.TUNMTU)
			}
			if inbound.TUNAutoRoute && (cfg.DNS.Mode != "doh" || strings.TrimSpace(cfg.DNS.Server) == "") {
				return fmt.Errorf("inbound %q: auto-route TUN requires encrypted DNS", inbound.Tag)
			}
		default:
			return fmt.Errorf("inbound %q: type %q is not implemented", inbound.Tag, inbound.Type)
		}
	}
	if !activeInbound {
		return fmt.Errorf("at least one supported proxy inbound is required")
	}
	if cfg.DNS.FakeIP != "" {
		return fmt.Errorf("DNS fakeip is not implemented")
	}
	if cfg.DNS.Mode != "" && cfg.DNS.Mode != "local" && cfg.DNS.Mode != "doh" {
		return fmt.Errorf("DNS mode %q is not implemented", cfg.DNS.Mode)
	}
	if cfg.DNS.Mode == "doh" && strings.TrimSpace(cfg.DNS.Server) == "" {
		return fmt.Errorf("DNS mode doh requires a server")
	}
	switch cfg.DNS.Strategy {
	case "", "prefer_ipv4", "prefer_ipv6", "ipv4_only", "ipv6_only":
	default:
		return fmt.Errorf("DNS strategy %q is not implemented", cfg.DNS.Strategy)
	}
	if len(cfg.Providers) > 0 {
		return fmt.Errorf("providers are not implemented")
	}

	known := map[string]bool{"direct": true}
	for _, node := range cfg.Nodes {
		if node.ID == "" {
			return fmt.Errorf("node id is required")
		}
		if known[node.ID] {
			return fmt.Errorf("duplicate outbound id %q", node.ID)
		}
		switch node.Type {
		case model.ProtocolVLESS, model.ProtocolTrojan, model.ProtocolHysteria2, model.ProtocolTUIC:
		default:
			return fmt.Errorf("node %q: protocol %q is not implemented", node.ID, node.Type)
		}
		if strings.TrimSpace(node.Server) == "" {
			return fmt.Errorf("node %q: server is required", node.ID)
		}
		if node.Port == 0 {
			return fmt.Errorf("node %q: server port must be between 1 and 65535", node.ID)
		}
		if node.TLS != nil && node.TLS.Reality != nil && node.TLS.Reality.Enabled {
			if strings.TrimSpace(node.TLS.Reality.PublicKey) == "" {
				return fmt.Errorf("node %q: REALITY public key is required", node.ID)
			}
			if strings.TrimSpace(node.TLS.ServerName) == "" {
				return fmt.Errorf("node %q: REALITY server name is required", node.ID)
			}
		}
		if node.Transport != nil {
			switch strings.ToLower(strings.TrimSpace(node.Transport.Type)) {
			case "", "raw", "tcp", "ws", "websocket", "grpc", "gun":
			default:
				return fmt.Errorf("node %q: transport %q is not implemented", node.ID, node.Transport.Type)
			}
		}
		known[node.ID] = true
	}
	for _, group := range cfg.Groups {
		if group.ID == "" {
			return fmt.Errorf("group id is required")
		}
		if known[group.ID] {
			return fmt.Errorf("duplicate outbound id %q", group.ID)
		}
		known[group.ID] = true
	}
	ruleSetIDs := make(map[string]bool, len(cfg.Rulesets))
	for _, ruleSet := range cfg.Rulesets {
		if ruleSet.ID == "" {
			return fmt.Errorf("remote rule set id is required")
		}
		if ruleSetIDs[ruleSet.ID] {
			return fmt.Errorf("duplicate rule set id %q", ruleSet.ID)
		}
		ruleSetIDs[ruleSet.ID] = true
		if ruleSet.Type != "" && ruleSet.Type != "remote" {
			return fmt.Errorf("rule set %q: type %q is not implemented", ruleSet.ID, ruleSet.Type)
		}
		if ruleSet.Format != "" && ruleSet.Format != "source" && ruleSet.Format != "binary" {
			return fmt.Errorf("rule set %q: format %q is not implemented", ruleSet.ID, ruleSet.Format)
		}
		parsed, err := url.ParseRequestURI(ruleSet.URL)
		if err != nil || parsed.Scheme != "http" && parsed.Scheme != "https" {
			return fmt.Errorf("rule set %q: invalid HTTP(S) URL %q", ruleSet.ID, ruleSet.URL)
		}
		if ruleSet.DownloadDetour != "" && !known[ruleSet.DownloadDetour] {
			return fmt.Errorf("rule set %q: download detour references unknown outbound %q", ruleSet.ID, ruleSet.DownloadDetour)
		}
		if ruleSet.UpdateInterval < 0 {
			return fmt.Errorf("rule set %q: update interval cannot be negative", ruleSet.ID)
		}
	}
	if cfg.DNS.Detour != "" && !known[cfg.DNS.Detour] {
		return fmt.Errorf("DNS detour references unknown outbound %q", cfg.DNS.Detour)
	}
	for _, group := range cfg.Groups {
		if group.Type != "select" && group.Type != "selector" && group.Type != "urltest" && group.Type != "url-test" {
			return fmt.Errorf("group %q: type %q is not implemented", group.ID, group.Type)
		}
		if len(group.Members) == 0 {
			return fmt.Errorf("group %q has no members", group.ID)
		}
		for _, member := range group.Members {
			if !known[member] || member == group.ID {
				return fmt.Errorf("group %q: invalid member %q", group.ID, member)
			}
		}
		if group.Default != "" && !contains(group.Members, group.Default) {
			return fmt.Errorf("group %q: default %q is not a member", group.ID, group.Default)
		}
	}
	if cfg.Route.Final == "" {
		cfg.Route.Final = "direct"
	}
	if !known[cfg.Route.Final] {
		return fmt.Errorf("route final references unknown outbound %q", cfg.Route.Final)
	}
	for index, rule := range cfg.Rules {
		if len(rule.Match.ProcessName) > 0 {
			return fmt.Errorf("rule %d: process matching is not implemented", index)
		}
		if rule.Action == model.ActionRoute && rule.Target != "" && !known[rule.Target] {
			return fmt.Errorf("rule %d references unknown outbound %q", index, rule.Target)
		}
		for _, id := range rule.Match.RuleSet {
			if !ruleSetIDs[id] {
				return fmt.Errorf("rule %d references unknown rule set %q", index, id)
			}
		}
	}
	if cfg.API.Listen == "" {
		cfg.API.Listen = "127.0.0.1:9090"
	}
	if _, _, err := net.SplitHostPort(cfg.API.Listen); err != nil {
		return fmt.Errorf("invalid API listen address %q: %w", cfg.API.Listen, err)
	}
	if _, collision := inboundAddresses[cfg.API.Listen]; collision {
		return fmt.Errorf("API listen address conflicts with inbound: %s", cfg.API.Listen)
	}
	return nil
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
