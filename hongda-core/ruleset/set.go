// Package ruleset loads and matches industry-standard source-format rule
// sets. The supported subset intentionally matches the remote rule sets used
// by Hongda Starlink subscriptions.
package ruleset

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/netip"
	"sort"
	"strings"
)

type Set struct {
	id       string
	domains  map[string]struct{}
	suffixes map[string]struct{}
	keywords []string
	prefixes []netip.Prefix
}

// NewEmpty creates an intentionally empty optional rule set. It is used only
// when every first-run download source is unavailable; the router can then
// fall back to its configured final outbound instead of preventing startup.
func NewEmpty(id string) *Set {
	return &Set{
		id:       id,
		domains:  make(map[string]struct{}),
		suffixes: make(map[string]struct{}),
	}
}

func (s *Set) ID() string { return s.id }

func (s *Set) MatchDomain(host string) bool {
	host = normalizeDomain(host)
	if host == "" {
		return false
	}
	if _, ok := s.domains[host]; ok {
		return true
	}
	part := host
	for {
		if _, ok := s.suffixes[part]; ok {
			return true
		}
		dot := strings.IndexByte(part, '.')
		if dot < 0 {
			break
		}
		part = part[dot+1:]
	}
	for _, keyword := range s.keywords {
		if strings.Contains(host, keyword) {
			return true
		}
	}
	return false
}

func (s *Set) MatchIP(address netip.Addr) bool {
	if !address.IsValid() {
		return false
	}
	address = address.Unmap()
	for _, prefix := range s.prefixes {
		if prefix.Contains(address) {
			return true
		}
	}
	return false
}

func (s *Set) HasIPRules() bool { return len(s.prefixes) > 0 }

type sourceDocument struct {
	Version int               `json:"version"`
	Rules   []json.RawMessage `json:"rules"`
}

var allowedRuleFields = map[string]bool{
	"type": true, "invert": true,
	"domain": true, "domain_suffix": true, "domain_keyword": true, "ip_cidr": true,
}

func ParseSource(id string, data []byte) (*Set, error) {
	var document sourceDocument
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&document); err != nil {
		return nil, fmt.Errorf("decode rule set %q: %w", id, err)
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return nil, fmt.Errorf("decode rule set %q: trailing JSON data", id)
	}
	if len(document.Rules) == 0 {
		return nil, fmt.Errorf("rule set %q contains no rules", id)
	}
	set := &Set{
		id:       id,
		domains:  make(map[string]struct{}),
		suffixes: make(map[string]struct{}),
	}
	keywordSeen := make(map[string]bool)
	prefixSeen := make(map[netip.Prefix]bool)
	for index, encoded := range document.Rules {
		var raw map[string]json.RawMessage
		if err := json.Unmarshal(encoded, &raw); err != nil {
			return nil, fmt.Errorf("rule set %q rule %d: %w", id, index, err)
		}
		for field := range raw {
			if !allowedRuleFields[field] {
				return nil, fmt.Errorf("rule set %q rule %d uses unsupported field %q", id, index, field)
			}
		}
		if encodedType, ok := raw["type"]; ok {
			var ruleType string
			if err := json.Unmarshal(encodedType, &ruleType); err != nil || ruleType != "" && ruleType != "default" {
				return nil, fmt.Errorf("rule set %q rule %d uses unsupported type", id, index)
			}
		}
		if encodedInvert, ok := raw["invert"]; ok {
			var invert bool
			if err := json.Unmarshal(encodedInvert, &invert); err != nil || invert {
				return nil, fmt.Errorf("rule set %q rule %d uses unsupported invert", id, index)
			}
		}
		domains, err := decodeStringList(raw["domain"])
		if err != nil {
			return nil, fmt.Errorf("rule set %q rule %d domain: %w", id, index, err)
		}
		for _, item := range domains {
			item = normalizeDomain(item)
			if item != "" {
				set.domains[item] = struct{}{}
			}
		}
		suffixes, err := decodeStringList(raw["domain_suffix"])
		if err != nil {
			return nil, fmt.Errorf("rule set %q rule %d domain_suffix: %w", id, index, err)
		}
		for _, item := range suffixes {
			item = normalizeDomain(strings.TrimPrefix(item, "."))
			if item != "" {
				set.suffixes[item] = struct{}{}
			}
		}
		keywords, err := decodeStringList(raw["domain_keyword"])
		if err != nil {
			return nil, fmt.Errorf("rule set %q rule %d domain_keyword: %w", id, index, err)
		}
		for _, item := range keywords {
			item = strings.ToLower(strings.TrimSpace(item))
			if item != "" && !keywordSeen[item] {
				keywordSeen[item] = true
				set.keywords = append(set.keywords, item)
			}
		}
		prefixes, err := decodeStringList(raw["ip_cidr"])
		if err != nil {
			return nil, fmt.Errorf("rule set %q rule %d ip_cidr: %w", id, index, err)
		}
		for _, item := range prefixes {
			prefix, err := netip.ParsePrefix(strings.TrimSpace(item))
			if err != nil {
				return nil, fmt.Errorf("rule set %q rule %d invalid ip_cidr %q: %w", id, index, item, err)
			}
			prefix = prefix.Masked()
			if !prefixSeen[prefix] {
				prefixSeen[prefix] = true
				set.prefixes = append(set.prefixes, prefix)
			}
		}
	}
	if len(set.domains) == 0 && len(set.suffixes) == 0 && len(set.keywords) == 0 && len(set.prefixes) == 0 {
		return nil, fmt.Errorf("rule set %q contains no supported entries", id)
	}
	sort.Slice(set.keywords, func(i, j int) bool { return len(set.keywords[i]) > len(set.keywords[j]) })
	return set, nil
}

func decodeStringList(encoded json.RawMessage) ([]string, error) {
	if len(encoded) == 0 || string(encoded) == "null" {
		return nil, nil
	}
	var values []string
	if json.Unmarshal(encoded, &values) == nil {
		return values, nil
	}
	var value string
	if json.Unmarshal(encoded, &value) == nil && value != "" {
		return []string{value}, nil
	}
	return nil, fmt.Errorf("expected string or string array")
}

func normalizeDomain(value string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(value), "."))
}
