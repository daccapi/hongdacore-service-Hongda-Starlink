package route

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/ruleset"
	"hongda.local/hongda-core/telemetry"
)

// Router is the single traffic decision point. It holds outbounds/groups and
// tracks byte counters for telemetry.
type Router struct {
	final      string
	outbounds  map[string]model.Outbound
	traffic    *telemetry.Traffic
	conns      *telemetry.Connections
	rules      []model.Rule
	ruleSets   map[string]*ruleset.Set
	dns        model.DNSOptions
	dnsMu      sync.Mutex
	dnsCache   map[string]dnsCacheEntry
	dnsReverse map[netip.Addr][]dnsReverseEntry
}

type dnsCacheEntry struct {
	ips     []net.IP
	expires time.Time
}

type dnsReverseEntry struct {
	domain  string
	expires time.Time
}

func New(final string, traffic *telemetry.Traffic, conns *telemetry.Connections) *Router {
	return &Router{
		final:      final,
		outbounds:  make(map[string]model.Outbound),
		ruleSets:   make(map[string]*ruleset.Set),
		dnsCache:   make(map[string]dnsCacheEntry),
		dnsReverse: make(map[netip.Addr][]dnsReverseEntry),
		traffic:    traffic,
		conns:      conns,
	}
}

func (r *Router) Register(ob model.Outbound) {
	r.outbounds[ob.ID()] = ob
}

func (r *Router) SetPolicy(rules []model.Rule, dns model.DNSOptions) {
	r.rules = rules
	r.dns = dns
}

func (r *Router) SetRuleSets(sets map[string]*ruleset.Set) {
	r.ruleSets = sets
}

// SetDirectInterface pins direct sockets to the physical adapter. Without
// this, a public DIRECT rule under auto-route can re-enter HongdaTun.
func (r *Router) SetDirectInterface(index int) {
	for _, outbound := range r.outbounds {
		if aware, ok := outbound.(model.InterfaceAware); ok {
			aware.SetInterfaceIndex(index)
		}
	}
}

func (r *Router) Outbounds() map[string]model.Outbound {
	return r.outbounds
}

func (r *Router) AddUpload(n int64) {
	if n > 0 {
		r.traffic.AddUpload(n)
	}
}

func (r *Router) AddDownload(n int64) {
	if n > 0 {
		r.traffic.AddDownload(n)
	}
}

// TrackConnection registers a non-stream flow (currently TUN UDP) so the
// control plane's connection list and DELETE /connections operate on real
// sockets.
func (r *Router) TrackConnection(network, destination string, closeFn func()) *telemetry.Connection {
	host, _, err := net.SplitHostPort(destination)
	if err != nil {
		host = destination
	}
	return r.conns.Add(network, host, destination, closeFn)
}

func (r *Router) UntrackConnection(conn *telemetry.Connection) {
	if conn != nil {
		r.conns.Remove(conn.ID)
	}
}

// ExchangeDNS resolves a raw DNS message through the configured encrypted DNS
// endpoint. TUN uses this entry point so applications never fall back to the
// physical adapter's plaintext DNS server.
func (r *Router) ExchangeDNS(ctx context.Context, query []byte) ([]byte, error) {
	if r.dns.Mode != "doh" || r.dns.Server == "" {
		return nil, fmt.Errorf("TUN DNS interception requires dns.mode=doh")
	}
	if r.rejectDNSQuestion(query) {
		return dnsErrorResponse(query, 3) // NXDOMAIN
	}
	if suppressDNSQuery(r.dns.Strategy, query) {
		return emptyDNSResponse(query)
	}
	var dialContext func(context.Context, string, string) (net.Conn, error)
	if r.dns.Detour != "" && r.dns.Detour != "direct" {
		target := r.resolve(r.dns.Detour)
		outbound, ok := r.outbounds[target]
		if !ok {
			return nil, errUnknownOutbound(target)
		}
		dialContext = outbound.DialContext
	}
	response, err := exchangeDoH(ctx, r.dns, query, dialContext)
	if err != nil {
		return nil, err
	}
	r.rememberDNSResponse(query, response)
	return response, nil
}

func (r *Router) rejectDNSQuestion(query []byte) bool {
	domain, _, err := dnsQuestion(query)
	if err != nil {
		return false
	}
	for _, rule := range r.rules {
		if rule.Action == model.ActionHijackDNS || len(rule.Match.ProcessName) > 0 {
			continue
		}
		m := rule.Match
		// ExchangeDNS is shared by UDP and TCP. Network-specific rules cannot
		// be decided here without changing their semantics.
		if m.Network != "" || len(m.Port) > 0 && !matchPort(m.Port, "53") {
			continue
		}
		hasDomainMatcher := len(m.Domain) > 0 || len(m.DomainSuffix) > 0 ||
			len(m.DomainKeyword) > 0 || len(m.RuleSet) > 0
		if !hasDomainMatcher {
			continue
		}
		if !containsString(m.Domain, domain) && !matchDomainSuffix(m.DomainSuffix, domain) &&
			!matchDomainKeyword(m.DomainKeyword, domain) && !r.matchRuleSetDomain(m.RuleSet, domain) {
			continue
		}
		return rule.Action == model.ActionReject
	}
	return false
}

func (r *Router) Dial(network, address string) (net.Conn, error) {
	return r.dialRouted(network, address, address)
}

// DialWithDomain selects the outbound using a sniffed destination domain but
// still dials the original destination IP. This covers browsers that use
// encrypted DNS, where TUN cannot observe the A/AAAA answer but TLS SNI is
// still available on the first TCP packet.
func (r *Router) DialWithDomain(network, address, domain string) (net.Conn, error) {
	routeAddress := address
	if domain = strings.TrimSpace(domain); domain != "" {
		if _, port, err := net.SplitHostPort(address); err == nil {
			routeAddress = net.JoinHostPort(domain, port)
		} else {
			routeAddress = domain
		}
	}
	return r.dialRouted(network, address, routeAddress)
}

func (r *Router) dialRouted(network, address, routeAddress string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	target, err := r.routeTarget(ctx, network, routeAddress)
	if err != nil {
		return nil, err
	}
	target = r.resolve(target)
	ob, ok := r.outbounds[target]
	if !ok {
		return nil, &net.OpError{Op: "dial", Err: errUnknownOutbound(target)}
	}
	if ob.Type() == model.ProtocolDirect && r.dns.Mode == "doh" && r.dns.Server != "" {
		if resolved, ok := r.resolveDirectAddress(ctx, address); ok {
			address = resolved
		}
	}
	return ob.DialContext(ctx, network, address)
}

// DialVia bypasses routing rules and uses a named outbound. It is used for
// bootstrapping remote rule sets through their configured download detour.
func (r *Router) DialVia(ctx context.Context, tag, network, address string) (net.Conn, error) {
	if tag == "" {
		tag = "direct"
	}
	target := r.resolve(tag)
	outbound, ok := r.outbounds[target]
	if !ok {
		return nil, errUnknownOutbound(target)
	}
	return outbound.DialContext(ctx, network, address)
}

func (r *Router) resolveDirectAddress(ctx context.Context, address string) (string, bool) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return "", false
	}
	if net.ParseIP(host) != nil {
		return "", false
	}
	ips, err := r.lookupIPs(ctx, host)
	if err != nil || len(ips) == 0 {
		return "", false
	}
	chosen := ips[0]
	for _, ip := range ips {
		if ip.To4() != nil {
			chosen = ip
			break
		}
	}
	return net.JoinHostPort(chosen.String(), port), true
}

func (r *Router) routeTarget(ctx context.Context, network, address string) (string, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		host = address
		port = ""
	}
	for _, rule := range r.rules {
		if !r.matchRule(ctx, rule, network, host, port) {
			continue
		}
		switch rule.Action {
		case model.ActionReject:
			return "", &net.OpError{Op: "dial", Err: errRuleReject(rule.Target)}
		case model.ActionHijackDNS:
			if rule.Target != "" {
				return rule.Target, nil
			}
			return "direct", nil
		case model.ActionRoute, "":
			if rule.Target != "" {
				return rule.Target, nil
			}
		}
	}
	if r.final == "" {
		return "direct", nil
	}
	return r.final, nil
}

func (r *Router) matchRule(ctx context.Context, rule model.Rule, network, host, port string) bool {
	m := rule.Match
	if m.Network != "" && !strings.EqualFold(m.Network, network) {
		return false
	}
	if len(m.Port) > 0 && !matchPort(m.Port, port) {
		return false
	}
	if len(m.ProcessName) > 0 {
		// Process matching is not available on the clean-room core yet.
		return false
	}
	return r.matchDestination(ctx, rule, host)
}

// The external-format destination fields form one logical group: domain,
// suffix, keyword, IP CIDR and rule-set references are ORed. Network and port
// above remain AND constraints.
func (r *Router) matchDestination(ctx context.Context, rule model.Rule, host string) bool {
	m := rule.Match
	hasAddressMatcher := len(m.Domain) > 0 || len(m.DomainSuffix) > 0 ||
		len(m.DomainKeyword) > 0 || len(m.IPCIDR) > 0 || len(m.RuleSet) > 0
	if !hasAddressMatcher {
		return true
	}

	host = strings.Trim(strings.TrimSpace(host), "[]")
	if address, err := netip.ParseAddr(host); err == nil {
		address = address.Unmap()
		if r.matchAddress(m, address) {
			return true
		}
		// TUN connections arrive as destination IPs. Recover the domain from
		// the DNS response that HongdaCore intercepted so domain/rule-set
		// policies keep working for real application traffic.
		for _, domain := range r.domainsForAddress(address) {
			if r.matchDomain(m, domain) {
				return true
			}
		}
		return false
	}
	if r.matchDomain(m, host) {
		return true
	}
	if rule.Options.NoResolve || !r.hasIPMatchers(m) {
		return false
	}
	ips, err := r.lookupIPs(ctx, host)
	if err != nil {
		return false
	}
	for _, ip := range ips {
		if address, ok := netip.AddrFromSlice(ip); ok && r.matchAddress(m, address.Unmap()) {
			return true
		}
	}
	return false
}

func (r *Router) matchDomain(match model.MatchExpr, host string) bool {
	return containsString(match.Domain, host) || matchDomainSuffix(match.DomainSuffix, host) ||
		matchDomainKeyword(match.DomainKeyword, host) || r.matchRuleSetDomain(match.RuleSet, host)
}

func (r *Router) matchRuleSetDomain(ids []string, host string) bool {
	for _, id := range ids {
		if set := r.ruleSets[id]; set != nil && set.MatchDomain(host) {
			return true
		}
	}
	return false
}

func (r *Router) hasIPMatchers(match model.MatchExpr) bool {
	if len(match.IPCIDR) > 0 {
		return true
	}
	for _, id := range match.RuleSet {
		if set := r.ruleSets[id]; set != nil && set.HasIPRules() {
			return true
		}
	}
	return false
}

func (r *Router) matchAddress(match model.MatchExpr, address netip.Addr) bool {
	for _, raw := range match.IPCIDR {
		if raw == "private" {
			if address.IsPrivate() || address.IsLoopback() || address.IsLinkLocalUnicast() {
				return true
			}
			continue
		}
		if prefix, err := netip.ParsePrefix(raw); err == nil && prefix.Contains(address) {
			return true
		}
	}
	for _, id := range match.RuleSet {
		if set := r.ruleSets[id]; set != nil && set.MatchIP(address) {
			return true
		}
	}
	return false
}

func containsString(list []string, value string) bool {
	v := strings.ToLower(strings.TrimSpace(value))
	for _, item := range list {
		if strings.EqualFold(item, v) {
			return true
		}
	}
	return false
}

func matchDomainSuffix(list []string, host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	for _, item := range list {
		suffix := strings.ToLower(strings.TrimSpace(item))
		suffix = strings.TrimPrefix(suffix, ".")
		if h == suffix || strings.HasSuffix(h, "."+suffix) {
			return true
		}
	}
	return false
}

func matchDomainKeyword(list []string, host string) bool {
	h := strings.ToLower(strings.TrimSpace(host))
	for _, item := range list {
		if strings.Contains(h, strings.ToLower(strings.TrimSpace(item))) {
			return true
		}
	}
	return false
}

func matchPort(list []string, port string) bool {
	for _, item := range list {
		item = strings.TrimSpace(item)
		if item == port {
			return true
		}
		if strings.Contains(item, "-") {
			parts := strings.SplitN(item, "-", 2)
			if len(parts) == 2 {
				lo, err1 := strconv.Atoi(parts[0])
				hi, err2 := strconv.Atoi(parts[1])
				p, err3 := strconv.Atoi(port)
				if err1 == nil && err2 == nil && err3 == nil && p >= lo && p <= hi {
					return true
				}
			}
		}
	}
	return false
}

func (r *Router) lookupIPs(ctx context.Context, host string) ([]net.IP, error) {
	cacheKey := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(host), "."))
	now := time.Now()
	r.dnsMu.Lock()
	if cached, ok := r.dnsCache[cacheKey]; ok && now.Before(cached.expires) {
		ips := cloneIPs(cached.ips)
		r.dnsMu.Unlock()
		return ips, nil
	}
	r.dnsMu.Unlock()

	var (
		ips []net.IP
		err error
	)
	if r.dns.Mode == "doh" && r.dns.Server != "" {
		var dialContext func(context.Context, string, string) (net.Conn, error)
		if r.dns.Detour != "" && r.dns.Detour != "direct" {
			target := r.resolve(r.dns.Detour)
			outbound, ok := r.outbounds[target]
			if !ok {
				return nil, errUnknownOutbound(target)
			}
			dialContext = outbound.DialContext
		}
		ips, err = lookupDoH(ctx, r.dns, host, dialContext)
	} else {
		ips, err = net.DefaultResolver.LookupIP(ctx, "ip", host)
	}
	if err != nil {
		return nil, err
	}
	r.dnsMu.Lock()
	if len(r.dnsCache) >= 4096 {
		for key, cached := range r.dnsCache {
			if now.After(cached.expires) {
				delete(r.dnsCache, key)
			}
		}
		if len(r.dnsCache) >= 4096 {
			for key := range r.dnsCache {
				delete(r.dnsCache, key)
				break
			}
		}
	}
	r.dnsCache[cacheKey] = dnsCacheEntry{ips: cloneIPs(ips), expires: now.Add(time.Minute)}
	r.dnsMu.Unlock()
	return ips, nil
}

func cloneIPs(values []net.IP) []net.IP {
	cloned := make([]net.IP, len(values))
	for index, value := range values {
		cloned[index] = append(net.IP(nil), value...)
	}
	return cloned
}

func (r *Router) resolve(tag string) string {
	seen := map[string]bool{}
	for {
		ob, ok := r.outbounds[tag]
		if !ok {
			return tag
		}
		if g, ok := ob.(model.Group); ok {
			if seen[tag] {
				return tag
			}
			seen[tag] = true
			tag = g.Current()
			continue
		}
		return tag
	}
}

func (r *Router) Pipe(client, upstream net.Conn) {
	host, _, _ := net.SplitHostPort(upstream.RemoteAddr().String())
	dest := upstream.RemoteAddr().String()
	r.pipe(client, upstream, host, dest)
}

// PipeTarget is the TUN-aware variant of Pipe. A proxied socket's RemoteAddr
// is the proxy server, while the dashboard must display the intercepted target.
func (r *Router) PipeTarget(client, upstream net.Conn, destination string) {
	host, _, err := net.SplitHostPort(destination)
	if err != nil {
		host = destination
	}
	r.pipe(client, upstream, host, destination)
}

func (r *Router) pipe(client, upstream net.Conn, host, dest string) {
	conn := r.conns.Add("tcp", host, dest, func() {
		_ = client.Close()
		_ = upstream.Close()
	})
	defer r.conns.Remove(conn.ID)

	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(&countWriter{
			Writer:   upstream,
			counter:  &conn.Upload,
			addTotal: r.traffic.AddUpload,
		}, client)
		closeWrite(upstream)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(&countWriter{
			Writer:   client,
			counter:  &conn.Download,
			addTotal: r.traffic.AddDownload,
		}, upstream)
		closeWrite(client)
		done <- struct{}{}
	}()
	<-done
	<-done
	conn.Close()
}

func closeWrite(conn net.Conn) {
	if halfCloser, ok := conn.(interface{ CloseWrite() error }); ok {
		_ = halfCloser.CloseWrite()
	}
}

type countWriter struct {
	io.Writer
	counter  *atomic.Int64
	addTotal func(int64)
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.Writer.Write(p)
	c.counter.Add(int64(n))
	c.addTotal(int64(n))
	return n, err
}

type unknownOutbound string

func (u unknownOutbound) Error() string { return "unknown outbound: " + string(u) }

func errUnknownOutbound(tag string) error { return unknownOutbound(tag) }

type ruleReject string

func (r ruleReject) Error() string {
	if r == "" {
		return "connection rejected by routing rule"
	}
	return "connection rejected by routing rule: " + string(r)
}

func errRuleReject(target string) error { return ruleReject(target) }
