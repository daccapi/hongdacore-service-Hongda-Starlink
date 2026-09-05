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
	"os"

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
	if cfg.Route.Final == "" {
		cfg.Route.Final = "direct"
	}
	if cfg.API.Listen == "" {
		cfg.API.Listen = "127.0.0.1:9090"
	}
	return nil
}
