package route

import (
	"context"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/telemetry"
)

// Router is the single traffic decision point. It holds outbounds/groups and
// tracks byte counters for telemetry.
type Router struct {
	final     string
	outbounds map[string]model.Outbound
	traffic   *telemetry.Traffic
	conns     *telemetry.Connections
	rules     []model.Rule
	dns       model.DNSOptions
}

func New(final string, traffic *telemetry.Traffic, conns *telemetry.Connections) *Router {
	return &Router{
		final:     final,
		outbounds: make(map[string]model.Outbound),
		traffic:   traffic,
		conns:     conns,
	}
}

func (r *Router) Register(ob model.Outbound) {
	r.outbounds[ob.ID()] = ob
}

func (r *Router) SetPolicy(rules []model.Rule, dns model.DNSOptions) {
	r.rules = rules
	r.dns = dns
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

func (r *Router) Dial(network, address string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	target, err := r.routeTarget(ctx, network, address)
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
	if len(m.Domain) > 0 && !containsString(m.Domain, host) {
		return false
	}
	if len(m.DomainSuffix) > 0 && !matchDomainSuffix(m.DomainSuffix, host) {
		return false
	}
	if len(m.DomainKeyword) > 0 && !matchDomainKeyword(m.DomainKeyword, host) {
		return false
	}
	if len(m.IPCIDR) > 0 && !r.matchIPCIDR(ctx, m.IPCIDR, host) {
		return false
	}
	if len(m.ProcessName) > 0 {
		// Process matching is not available on the clean-room core yet.
		return false
	}
	return true
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

func (r *Router) matchIPCIDR(ctx context.Context, prefixes []string, host string) bool {
	if ip, err := netip.ParseAddr(host); err == nil {
		for _, p := range prefixes {
			if p == "private" {
				if ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
					return true
				}
				continue
			}
			if prefix, err := netip.ParsePrefix(p); err == nil && prefix.Contains(ip) {
				return true
			}
		}
		return false
	}
	ips, err := r.lookupIPs(ctx, host)
	if err != nil {
		return false
	}
	for _, ip := range ips {
		addr, ok := netip.AddrFromSlice(ip)
		if !ok {
			continue
		}
		addr = addr.Unmap()
		for _, p := range prefixes {
			if p == "private" {
				if addr.IsPrivate() || addr.IsLoopback() || addr.IsLinkLocalUnicast() {
					return true
				}
				continue
			}
			if prefix, err := netip.ParsePrefix(p); err == nil && prefix.Contains(addr) {
				return true
			}
		}
	}
	return false
}

func (r *Router) lookupIPs(ctx context.Context, host string) ([]net.IP, error) {
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
		return lookupDoH(ctx, r.dns, host, dialContext)
	}
	return net.DefaultResolver.LookupIP(ctx, "ip", host)
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
