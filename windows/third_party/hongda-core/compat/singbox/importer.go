// Package singbox imports external-format JSON configurations into Hongda's
// unified Config model. It is an import-only adapter: after Import returns,
// the runtime never sees the external JSON format again.
//
// This keeps Hongda compatible with the existing Flutter UI (which still emits
// the external JSON format) while letting the core operate on its own data
// model, as required by the Hongda Core design document section 5.
package singbox

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"hongda.local/hongda-core/model"
)

// Import converts an external-format JSON document (already decoded into a generic
// map) into a Hongda Config. Cosmetic unknown fields are ignored, but fields
// that change traffic, DNS or routing semantics are rejected until Hongda can
// implement them faithfully. Silently dropping those fields caused earlier
// builds to report a healthy connection while bypassing the requested TUN or
// routing policy.
func Import(raw map[string]interface{}) (*model.Config, error) {
	cfg := &model.Config{
		Core: model.CoreOptions{},
		DNS:  model.DNSOptions{Mode: "local"},
		Route: model.RouteConfig{
			Final: "direct",
		},
		Log: model.LogOptions{Level: "warn", Timestamp: true},
	}
	if endpoints, ok := raw["endpoints"].([]interface{}); ok && len(endpoints) > 0 {
		return nil, fmt.Errorf("endpoints are not implemented by HongdaCore 1.10")
	}

	if logRaw, ok := raw["log"].(map[string]interface{}); ok {
		if v, ok := logRaw["level"].(string); ok && v != "" {
			cfg.Log.Level = v
		}
		if v, ok := logRaw["timestamp"].(bool); ok {
			cfg.Log.Timestamp = v
		}
	}

	if dnsRaw, ok := raw["dns"].(map[string]interface{}); ok {
		cfg.DNS.Strategy = getString(dnsRaw, "strategy")
		if servers, ok := dnsRaw["servers"].([]interface{}); ok && len(servers) > 0 {
			for _, s := range servers {
				if sm, ok := s.(map[string]interface{}); ok {
					typ := getString(sm, "type")
					switch typ {
					case "", "local":
						// Local resolution is the default and needs no adapter.
					case "https":
						cfg.DNS.Mode = "doh"
						cfg.DNS.Detour = getString(sm, "detour")
						host := getString(sm, "server")
						if host == "" {
							return nil, fmt.Errorf("dns server %q: https server is empty", getString(sm, "tag"))
						}
						port := getInt(sm, "server_port")
						if port > 0 && port != 443 {
							host = netJoinHostPort(host, port)
						}
						path := getString(sm, "path")
						if path == "" {
							path = "/dns-query"
						}
						if !strings.HasPrefix(path, "/") {
							path = "/" + path
						}
						cfg.DNS.Server = "https://" + host + path
						if tlsRaw, ok := sm["tls"].(map[string]interface{}); ok {
							cfg.DNS.TLSServer = getString(tlsRaw, "server_name")
						}
					case "fakeip":
						return nil, fmt.Errorf("dns server %q: fakeip is not implemented", getString(sm, "tag"))
					default:
						return nil, fmt.Errorf("dns server %q: type %q is not implemented", getString(sm, "tag"), typ)
					}
				}
			}
		}
	}

	if exp, ok := raw["experimental"].(map[string]interface{}); ok {
		if clash, ok := exp["clash_api"].(map[string]interface{}); ok {
			if ec, ok := clash["external_controller"].(string); ok && ec != "" {
				cfg.API.Listen = ec
			}
			if secret, ok := clash["secret"].(string); ok {
				cfg.API.Secret = secret
			}
		}
	}

	if inbounds, ok := raw["inbounds"].([]interface{}); ok {
		for _, ib := range inbounds {
			im, ok := ib.(map[string]interface{})
			if !ok {
				continue
			}
			ic := model.InboundConfig{
				Type: getString(im, "type"),
				Tag:  getString(im, "tag"),
			}
			switch ic.Type {
			case "mixed", "socks", "http":
				ic.Listen = getString(im, "listen")
				if ic.Listen == "" {
					ic.Listen = "127.0.0.1"
				}
				ic.Port = uint16(getInt(im, "listen_port"))
			case "tun":
				ic.TUNAddress = getStringList(im, "address")
				ic.TUNMTU = getInt(im, "mtu")
				ic.TUNAutoRoute = getBool(im, "auto_route")
				ic.TUNStrictRoute = getBool(im, "strict_route")
				ic.TUNStack = getString(im, "stack")
				ic.TUNInterface = getString(im, "interface_name")
				ic.TUNRouteAddr = getStringList(im, "route_address")
			default:
				return nil, fmt.Errorf("inbound %q: type %q is not implemented", ic.Tag, ic.Type)
			}
			cfg.Inbounds = append(cfg.Inbounds, ic)
		}
	}

	// First pass: collect every outbound tag so group member references can be
	// resolved even when a group appears before its members.
	outbounds, _ := raw["outbounds"].([]interface{})
	knownTags := make(map[string]bool, len(outbounds))
	for _, ob := range outbounds {
		if om, ok := ob.(map[string]interface{}); ok {
			if tag, ok := om["tag"].(string); ok {
				knownTags[tag] = true
			}
		}
	}

	for _, ob := range outbounds {
		om, ok := ob.(map[string]interface{})
		if !ok {
			continue
		}
		tag := getString(om, "tag")
		if tag == "" {
			continue
		}
		typ := getString(om, "type")
		switch typ {
		case "direct":
			// Registered implicitly by the runtime; nothing to compile.
		case "block", "dns":
			// Reserved tags for REJECT / DNS actions; tracked via rules.
		case "selector", "urltest":
			gc := model.GroupConfig{
				ID:   tag,
				Type: mapGroupType(typ),
			}
			if members, ok := om["outbounds"].([]interface{}); ok {
				for _, m := range members {
					if name, ok := m.(string); ok && knownTags[name] {
						gc.Members = append(gc.Members, name)
					}
				}
			}
			if def, ok := om["default"].(string); ok {
				gc.Default = def
			}
			if typ == "urltest" {
				gc.URL = getString(om, "url")
				gc.Interval = parseDurationSeconds(getString(om, "interval"))
				gc.Tolerance = getInt(om, "tolerance")
			}
			cfg.Groups = append(cfg.Groups, gc)
		case "fallback", "load-balance":
			return nil, fmt.Errorf("outbound %q: group type %q is not implemented", tag, typ)
		default:
			node, err := convertNode(tag, typ, om)
			if err != nil {
				return nil, fmt.Errorf("outbound %q: %w", tag, err)
			}
			cfg.Nodes = append(cfg.Nodes, node)
		}
	}

	if route, ok := raw["route"].(map[string]interface{}); ok {
		if sets, ok := route["rule_set"].([]interface{}); ok {
			for _, item := range sets {
				setRaw, ok := item.(map[string]interface{})
				if !ok {
					return nil, fmt.Errorf("route.rule_set contains a non-object entry")
				}
				setType := getString(setRaw, "type")
				if setType == "" {
					setType = "remote"
				}
				if setType != "remote" {
					return nil, fmt.Errorf("rule set %q: type %q is not implemented", getString(setRaw, "tag"), setType)
				}
				format := getString(setRaw, "format")
				if format == "" {
					format = "source"
				}
				if format != "source" && format != "binary" {
					return nil, fmt.Errorf("rule set %q: format %q is not implemented", getString(setRaw, "tag"), format)
				}
				ruleSet := model.RulesetConfig{
					ID:             getString(setRaw, "tag"),
					Type:           setType,
					Format:         format,
					URL:            getString(setRaw, "url"),
					FallbackURLs:   getStringList(setRaw, "download_fallback_url"),
					DownloadDetour: getString(setRaw, "download_detour"),
					UpdateInterval: parseDurationSeconds(getString(setRaw, "update_interval")),
					Optional:       getBool(setRaw, "download_optional"),
				}
				if ruleSet.ID == "" || ruleSet.URL == "" {
					return nil, fmt.Errorf("remote rule set requires tag and url")
				}
				cfg.Rulesets = append(cfg.Rulesets, ruleSet)
			}
		}
		if fin, ok := route["final"].(string); ok && fin != "" {
			cfg.Route.Final = fin
		}
		if rules, ok := route["rules"].([]interface{}); ok {
			for _, r := range rules {
				rm, ok := r.(map[string]interface{})
				if !ok {
					continue
				}
				if _, exists := rm["process_name"]; exists {
					return nil, fmt.Errorf("route process_name matching is not implemented")
				}
				rule, ok := convertRule(rm)
				if !ok {
					continue
				}
				cfg.Rules = append(cfg.Rules, rule)
			}
		}
	}

	if cfg.API.Listen == "" {
		cfg.API.Listen = "127.0.0.1:9090"
	}
	return cfg, nil
}

func netJoinHostPort(host string, port int) string {
	if strings.Contains(host, ":") && !strings.HasPrefix(host, "[") {
		host = "[" + host + "]"
	}
	return host + ":" + strconv.Itoa(port)
}

// ImportBytes is a convenience wrapper around Import for raw JSON documents.
func ImportBytes(data []byte) (*model.Config, error) {
	var raw map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, fmt.Errorf("decode json config: %w", err)
	}
	return Import(raw)
}

func mapGroupType(t string) string {
	switch t {
	case "selector":
		return "select"
	case "urltest":
		return "urltest"
	case "fallback":
		return "fallback"
	case "load-balance":
		return "balance"
	}
	return t
}

func convertNode(tag, typ string, om map[string]interface{}) (model.Node, error) {
	switch typ {
	case "vless", "trojan", "hysteria2", "tuic":
	default:
		return model.Node{}, fmt.Errorf("protocol %q is not implemented by HongdaCore 1.10", typ)
	}

	node := model.Node{
		ID:   tag,
		Name: tag,
		Type: model.ProtocolType(typ),
		Auth: make(map[string]string),
	}
	node.Server = getString(om, "server")
	port := getInt(om, "server_port")
	if port < 1 || port > 65535 {
		return model.Node{}, fmt.Errorf("server port must be between 1 and 65535")
	}
	node.Port = uint16(port)
	if v, ok := om["udp"].(bool); ok {
		node.UDP = v
	}

	// Protocol-specific auth fields.
	switch typ {
	case "vless":
		if uuid, ok := om["uuid"].(string); ok {
			node.Auth["uuid"] = uuid
		}
		if flow, ok := om["flow"].(string); ok {
			node.Auth["flow"] = flow
		}
		if pe, ok := om["packet_encoding"].(string); ok {
			node.Auth["packet_encoding"] = pe
		}
	case "trojan":
		if pw, ok := om["password"].(string); ok {
			node.Auth["password"] = pw
		}
	case "vmess":
		if uuid, ok := om["uuid"].(string); ok {
			node.Auth["uuid"] = uuid
		}
		if aid, ok := om["alter_id"]; ok {
			node.Auth["alter_id"] = fmt.Sprintf("%v", aid)
		}
		if sec, ok := om["security"].(string); ok {
			node.Auth["security"] = sec
		}
	case "shadowsocks":
		if m, ok := om["method"].(string); ok {
			node.Auth["method"] = m
		}
		if pw, ok := om["password"].(string); ok {
			node.Auth["password"] = pw
		}
	case "hysteria2":
		if pw, ok := om["password"].(string); ok {
			node.Auth["password"] = pw
		}
		if obfs, ok := om["obfs"].(map[string]interface{}); ok {
			obfsType := strings.ToLower(strings.TrimSpace(getString(obfs, "type")))
			switch obfsType {
			case "":
			case "salamander":
				obfsPassword := getString(obfs, "password")
				if obfsPassword == "" {
					return model.Node{}, fmt.Errorf("hysteria2 salamander password is required")
				}
				node.Auth["obfs"] = obfsType
				node.Auth["obfs_password"] = obfsPassword
			default:
				return model.Node{}, fmt.Errorf("hysteria2 obfs %q is not implemented", obfsType)
			}
		}
		if up, ok := om["up_mbps"]; ok {
			node.Auth["up_mbps"] = fmt.Sprintf("%v", up)
		}
		if down, ok := om["down_mbps"]; ok {
			node.Auth["down_mbps"] = fmt.Sprintf("%v", down)
		}
	case "tuic":
		if uuid, ok := om["uuid"].(string); ok {
			node.Auth["uuid"] = uuid
		}
		if pw, ok := om["password"].(string); ok {
			node.Auth["password"] = pw
		}
		if cc, ok := om["congestion_control"].(string); ok {
			if cc != "" && !strings.EqualFold(cc, "cubic") {
				return model.Node{}, fmt.Errorf("tuic congestion control %q is not implemented; use cubic", cc)
			}
			node.Auth["congestion_control"] = cc
		}
		if zeroRTT, ok := om["zero_rtt_handshake"].(bool); ok && zeroRTT {
			return model.Node{}, fmt.Errorf("tuic zero_rtt_handshake is not implemented")
		}
		if relay := strings.TrimSpace(getString(om, "udp_relay_mode")); relay != "" && relay != "native" {
			return model.Node{}, fmt.Errorf("tuic udp_relay_mode %q is not implemented; use native", relay)
		}
	}

	if tlsRaw, ok := om["tls"].(map[string]interface{}); ok {
		tls := &model.TLSOptions{
			Enabled:    getBool(tlsRaw, "enabled"),
			ServerName: getString(tlsRaw, "server_name"),
			Insecure:   getBool(tlsRaw, "insecure"),
		}
		if !tls.Enabled {
			// The external format implies TLS enabled when a tls block is
			// present with reality or a server_name.
			if tls.ServerName != "" {
				tls.Enabled = true
			}
		}
		if utls, ok := tlsRaw["utls"].(map[string]interface{}); ok {
			if fp, ok := utls["fingerprint"].(string); ok {
				tls.UTLSFingerprint = fp
			}
		}
		if reality, ok := tlsRaw["reality"].(map[string]interface{}); ok {
			r := &model.RealityOptions{
				Enabled: getBool(reality, "enabled"),
			}
			if r.Enabled {
				tls.Enabled = true
			}
			r.PublicKey = getString(reality, "public_key")
			r.ShortID = getString(reality, "short_id")
			tls.Reality = r
		}
		node.TLS = tls
	}

	if tpRaw, ok := om["transport"].(map[string]interface{}); ok {
		tp := &model.TransportOptions{
			Type: getString(tpRaw, "type"),
		}
		switch tp.Type {
		case "", "raw", "tcp":
		case "ws":
			tp.Path = getString(tpRaw, "path")
			if headers, ok := tpRaw["headers"].(map[string]interface{}); ok {
				if host, ok := headers["Host"].(string); ok {
					tp.Host = host
				}
			}
		case "grpc":
			tp.ServiceName = getString(tpRaw, "service_name")
		case "http":
			return model.Node{}, fmt.Errorf("HTTP transport is not implemented; use raw, WebSocket or gRPC")
		default:
			return model.Node{}, fmt.Errorf("transport %q is not implemented", tp.Type)
		}
		node.Transport = tp
	}
	if multiplex, ok := om["multiplex"].(map[string]interface{}); ok && getBool(multiplex, "enabled") {
		return model.Node{}, fmt.Errorf("multiplex is not implemented")
	}

	return node, nil
}

func convertRule(rm map[string]interface{}) (model.Rule, bool) {
	rule := model.Rule{}
	match := model.MatchExpr{}

	if v, ok := rm["domain"].([]interface{}); ok {
		for _, d := range v {
			if s, ok := d.(string); ok {
				match.Domain = append(match.Domain, s)
			}
		}
	}
	if v, ok := rm["domain_suffix"].([]interface{}); ok {
		for _, d := range v {
			if s, ok := d.(string); ok {
				match.DomainSuffix = append(match.DomainSuffix, s)
			}
		}
	}
	if v, ok := rm["domain_keyword"].([]interface{}); ok {
		for _, d := range v {
			if s, ok := d.(string); ok {
				match.DomainKeyword = append(match.DomainKeyword, s)
			}
		}
	}
	if v, ok := rm["ip_cidr"].([]interface{}); ok {
		for _, d := range v {
			if s, ok := d.(string); ok {
				match.IPCIDR = append(match.IPCIDR, s)
			}
		}
	}
	if v, ok := rm["process_name"].([]interface{}); ok {
		for _, d := range v {
			if s, ok := d.(string); ok {
				match.ProcessName = append(match.ProcessName, s)
			}
		}
	}
	if v, ok := rm["port"].([]interface{}); ok {
		for _, d := range v {
			match.Port = append(match.Port, fmt.Sprintf("%v", d))
		}
	} else if v, ok := rm["port"]; ok {
		match.Port = append(match.Port, fmt.Sprintf("%v", v))
	}
	if v, ok := rm["network"].(string); ok {
		match.Network = v
	}
	match.RuleSet = getStringList(rm, "rule_set")

	action := getString(rm, "action")
	switch action {
	case "reject":
		rule.Action = model.ActionReject
	case "hijack-dns":
		rule.Action = model.ActionHijackDNS
	case "route", "":
		rule.Action = model.ActionRoute
		rule.Target = getString(rm, "outbound")
	default:
		rule.Action = model.ActionRoute
		rule.Target = getString(rm, "outbound")
	}

	if private, ok := rm["ip_is_private"].(bool); ok && private {
		match.IPCIDR = append(match.IPCIDR, "private")
	}

	rule.Match = match
	hasMatcher := len(match.Domain) > 0 || len(match.DomainSuffix) > 0 ||
		len(match.DomainKeyword) > 0 || len(match.IPCIDR) > 0 ||
		len(match.ProcessName) > 0 || match.Network != "" || len(match.Port) > 0
	hasMatcher = hasMatcher || len(match.RuleSet) > 0
	if !hasMatcher && rule.Target == "" {
		return rule, false
	}
	return rule, true
}

func getString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func getInt(m map[string]interface{}, key string) int {
	switch v := m[key].(type) {
	case float64:
		return int(v)
	case int:
		return v
	case json.Number:
		n, _ := v.Int64()
		return int(n)
	case string:
		n, _ := strconv.Atoi(v)
		return n
	}
	return 0
}

func getBool(m map[string]interface{}, key string) bool {
	if v, ok := m[key].(bool); ok {
		return v
	}
	return false
}

func getStringList(m map[string]interface{}, key string) []string {
	value, ok := m[key]
	if !ok {
		return nil
	}
	switch list := value.(type) {
	case []interface{}:
		out := make([]string, 0, len(list))
		for _, item := range list {
			if text, ok := item.(string); ok && strings.TrimSpace(text) != "" {
				out = append(out, text)
			}
		}
		return out
	case string:
		if strings.TrimSpace(list) != "" {
			return []string{list}
		}
	}
	return nil
}

// parseDurationSeconds turns "30s" / "5m" into an integer second count.
func parseDurationSeconds(s string) int {
	if s == "" {
		return 0
	}
	s = strings.TrimSpace(s)
	mult := 1
	switch {
	case strings.HasSuffix(s, "s"):
		s = strings.TrimSuffix(s, "s")
	case strings.HasSuffix(s, "m"):
		s = strings.TrimSuffix(s, "m")
		mult = 60
	case strings.HasSuffix(s, "h"):
		s = strings.TrimSuffix(s, "h")
		mult = 3600
	case strings.HasSuffix(s, "d"):
		s = strings.TrimSuffix(s, "d")
		mult = 86400
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0
	}
	return n * mult
}
