package ruleset

import (
	"net/netip"
	"testing"
)

func TestParseAndMatchSource(t *testing.T) {
	set, err := ParseSource("sample", []byte(`{
  "version": 3,
  "rules": [{
    "domain": ["exact.example"],
    "domain_suffix": ["example.com"],
    "domain_keyword": ["advert"],
    "ip_cidr": ["203.0.113.0/24"]
  }]
}`))
	if err != nil {
		t.Fatal(err)
	}
	for _, host := range []string{"exact.example", "www.example.com", "cdn-advert.test"} {
		if !set.MatchDomain(host) {
			t.Fatalf("domain %q did not match", host)
		}
	}
	if set.MatchDomain("example.net") {
		t.Fatal("unexpected domain match")
	}
	if !set.MatchIP(netip.MustParseAddr("203.0.113.9")) || set.MatchIP(netip.MustParseAddr("198.51.100.1")) {
		t.Fatal("IP matching failed")
	}
}

func TestParseRejectsUnsupportedField(t *testing.T) {
	_, err := ParseSource("bad", []byte(`{"version":3,"rules":[{"domain_regex":[".*"]}]}`))
	if err == nil {
		t.Fatal("expected unsupported-field error")
	}
}

func TestPrefixTrieMatchesIPv4AndIPv6(t *testing.T) {
	set, err := ParseSource("ip", []byte(`{
  "version": 3,
  "rules": [{
    "ip_cidr": ["0.0.0.0/0", "203.0.113.0/24", "2001:db8:1234::/48"]
  }]
}`))
	if err != nil {
		t.Fatal(err)
	}
	if !set.HasIPRules() {
		t.Fatal("expected IP rules")
	}
	for _, value := range []string{"198.51.100.1", "203.0.113.9", "2001:db8:1234::42"} {
		if !set.MatchIP(netip.MustParseAddr(value)) {
			t.Fatalf("address %q did not match", value)
		}
	}
	if set.MatchIP(netip.MustParseAddr("2001:db8:ffff::1")) {
		t.Fatal("unexpected IPv6 match")
	}
}
