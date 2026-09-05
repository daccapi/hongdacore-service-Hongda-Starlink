// Package config loads Hongda runtime configurations from disk and validates
// them. It is the single entry point used by both the `check` and `run` CLI
// commands. Supported import formats are detected automatically:
//
//   - sing-box JSON (top-level "outbounds" + "inbounds") — converted via
//     compat/singbox so the existing Flutter UI keeps working unchanged.
//   - Hongda native JSON ("nodes"/"groups"/"rules" top-level) — decoded
//     directly into model.Config.
//
// Clash YAML import is planned for a later phase.
package config

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
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
	autoRouteTUN := false
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
			autoRouteTUN = autoRouteTUN || inbound.TUNAutoRoute
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
	if len(cfg.Providers) > 0 || len(cfg.Rulesets) > 0 {
		return fmt.Errorf("providers and remote rule sets are not implemented")
	}

	known := map[string]bool{"direct": true}
	for _, node := range cfg.Nodes {
		if node.ID == "" {
			return fmt.Errorf("node id is required")
		}
		if known[node.ID] {
			return fmt.Errorf("duplicate outbound id %q", node.ID)
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
	groupsByID := make(map[string]model.GroupConfig, len(cfg.Groups))
	for _, group := range cfg.Groups {
		groupsByID[group.ID] = group
	}
	if autoRouteTUN && targetMayUseDirect(cfg.Route.Final, groupsByID, make(map[string]bool)) {
		return fmt.Errorf("auto-route TUN final outbound %q may select direct and loop back into TUN", cfg.Route.Final)
	}
	for index, rule := range cfg.Rules {
		if len(rule.Match.ProcessName) > 0 {
			return fmt.Errorf("rule %d: process matching is not implemented", index)
		}
		if rule.Action == model.ActionRoute && rule.Target != "" && !known[rule.Target] {
			return fmt.Errorf("rule %d references unknown outbound %q", index, rule.Target)
		}
		if autoRouteTUN && rule.Action == model.ActionRoute && rule.Target != "" &&
			targetMayUseDirect(rule.Target, groupsByID, make(map[string]bool)) && !localDirectRule(rule) {
			return fmt.Errorf("rule %d can send public traffic direct and loop back into auto-route TUN", index)
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

func targetMayUseDirect(target string, groups map[string]model.GroupConfig, seen map[string]bool) bool {
	if target == "direct" {
		return true
	}
	if seen[target] {
		return false
	}
	seen[target] = true
	group, ok := groups[target]
	if !ok {
		return false
	}
	for _, member := range group.Members {
		if targetMayUseDirect(member, groups, seen) {
			return true
		}
	}
	return false
}

func localDirectRule(rule model.Rule) bool {
	match := rule.Match
	if len(match.Domain) > 0 || len(match.DomainSuffix) > 0 || len(match.DomainKeyword) > 0 ||
		len(match.ProcessName) > 0 || match.Network != "" || len(match.Port) > 0 || len(match.IPCIDR) == 0 {
		return false
	}
	for _, raw := range match.IPCIDR {
		if raw == "private" {
			continue
		}
		prefix, err := netip.ParsePrefix(raw)
		if err != nil || !(prefix.Addr().IsPrivate() || prefix.Addr().IsLoopback() || prefix.Addr().IsLinkLocalUnicast()) {
			return false
		}
	}
	return true
}

func contains(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
