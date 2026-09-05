package route

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"hongda.local/hongda-core/model"
)

// lookupDoH performs a minimal RFC 8484 DNS-over-HTTPS A/AAAA lookup. It is
// used only for IP-based routing decisions when dns.mode is set to "doh".
func lookupDoH(ctx context.Context, options model.DNSOptions, host string, dialContext func(context.Context, string, string) (net.Conn, error)) ([]net.IP, error) {
	server := strings.TrimSpace(options.Server)
	if server == "" {
		return nil, fmt.Errorf("doh server is empty")
	}
	if !strings.HasPrefix(server, "http://") && !strings.HasPrefix(server, "https://") {
		server = "https://" + server
	}
	u, err := url.Parse(server)
	if err != nil {
		return nil, fmt.Errorf("parse doh server: %w", err)
	}

	var ips []net.IP
	for _, qtype := range []uint16{1, 28} {
		query := buildDNSQuery(host, qtype)
		data, err := exchangeDoHURL(ctx, options, u, query, dialContext)
		if err != nil {
			return nil, err
		}
		parsed, err := parseDNSAnswers(data, qtype)
		if err != nil {
			return nil, err
		}
		ips = append(ips, parsed...)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("doh returned no addresses for %s", host)
	}
	return ips, nil
}

// exchangeDoH sends an unmodified DNS wire packet to the configured RFC 8484
// endpoint. Keeping the original transaction ID and all question flags makes
// it suitable for TUN DNS interception, not just internal address lookups.
func exchangeDoH(ctx context.Context, options model.DNSOptions, query []byte, dialContext func(context.Context, string, string) (net.Conn, error)) ([]byte, error) {
	server := strings.TrimSpace(options.Server)
	if server == "" {
		return nil, fmt.Errorf("doh server is empty")
	}
	if !strings.HasPrefix(server, "http://") && !strings.HasPrefix(server, "https://") {
		server = "https://" + server
	}
	u, err := url.Parse(server)
	if err != nil {
		return nil, fmt.Errorf("parse doh server: %w", err)
	}
	return exchangeDoHURL(ctx, options, u, query, dialContext)
}

func exchangeDoHURL(ctx context.Context, options model.DNSOptions, u *url.URL, query []byte, dialContext func(context.Context, string, string) (net.Conn, error)) ([]byte, error) {
	transport := newDoHTransport(options, dialContext)
	defer transport.CloseIdleConnections()
	return exchangeDoHURLWithClient(ctx, &http.Client{Transport: transport}, u, query)
}

func newDoHTransport(options model.DNSOptions, dialContext func(context.Context, string, string) (net.Conn, error)) *http.Transport {
	transport := &http.Transport{
		Proxy:                 nil,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          16,
		MaxIdleConnsPerHost:   8,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   8 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
		TLSClientConfig: &tls.Config{
			ServerName: options.TLSServer,
		},
	}
	if dialContext != nil {
		transport.DialContext = dialContext
	}
	return transport
}

func exchangeDoHURLWithClient(ctx context.Context, client *http.Client, u *url.URL, query []byte) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), bytes.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/dns-message")
	req.Header.Set("Content-Type", "application/dns-message")
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("doh query: %w", err)
	}
	data, readErr := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	_ = resp.Body.Close()
	if readErr != nil {
		return nil, readErr
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("doh status %d", resp.StatusCode)
	}
	if len(data) < 12 {
		return nil, fmt.Errorf("doh response too short")
	}
	return data, nil
}

type dnsMessageCacheEntry struct {
	response []byte
	expires  time.Time
}

type dnsMessageCall struct {
	done     chan struct{}
	response []byte
	err      error
}

func (r *Router) dohHTTPClient(dialContext func(context.Context, string, string) (net.Conn, error)) *http.Client {
	r.dohMu.Lock()
	defer r.dohMu.Unlock()
	if r.dohClient != nil {
		return r.dohClient
	}
	transport := newDoHTransport(r.dns, dialContext)
	r.dohTransport = transport
	r.dohClient = &http.Client{Transport: transport}
	return r.dohClient
}

// exchangeDoHCached reuses a small HTTP/2 or HTTP/1.1 connection pool and
// coalesces identical in-flight questions. V1.10.5 built and discarded one
// HTTP transport for every DNS packet, so a new web page paid a complete
// VLESS/WebSocket/TLS/DoH handshake for each hostname.
func (r *Router) exchangeDoHCached(ctx context.Context, query []byte, dialContext func(context.Context, string, string) (net.Conn, error)) ([]byte, error) {
	key := dnsMessageKey(query)
	if key == "" {
		return exchangeDoH(ctx, r.dns, query, dialContext)
	}

	now := time.Now()
	r.dnsMu.Lock()
	if cached, ok := r.dnsMessages[key]; ok && now.Before(cached.expires) {
		response := dnsResponseForQuery(cached.response, query)
		r.dnsMu.Unlock()
		return response, nil
	}
	if call := r.dnsFlights[key]; call != nil {
		r.dnsMu.Unlock()
		select {
		case <-call.done:
			return dnsResponseForQuery(call.response, query), call.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	call := &dnsMessageCall{done: make(chan struct{})}
	r.dnsFlights[key] = call
	r.dnsMu.Unlock()

	server := strings.TrimSpace(r.dns.Server)
	if !strings.HasPrefix(server, "http://") && !strings.HasPrefix(server, "https://") {
		server = "https://" + server
	}
	u, parseErr := url.Parse(server)
	var response []byte
	var queryErr error
	if parseErr != nil {
		queryErr = fmt.Errorf("parse doh server: %w", parseErr)
	} else {
		response, queryErr = exchangeDoHURLWithClient(ctx, r.dohHTTPClient(dialContext), u, query)
	}

	stored := dnsResponseForQuery(response, nil)
	r.dnsMu.Lock()
	call.response = stored
	call.err = queryErr
	if queryErr == nil && dnsResponseCacheable(response) {
		if len(r.dnsMessages) >= 4096 {
			for cacheKey, entry := range r.dnsMessages {
				if now.After(entry.expires) {
					delete(r.dnsMessages, cacheKey)
				}
			}
			if len(r.dnsMessages) >= 4096 {
				for cacheKey := range r.dnsMessages {
					delete(r.dnsMessages, cacheKey)
					break
				}
			}
		}
		r.dnsMessages[key] = dnsMessageCacheEntry{
			response: stored,
			expires:  time.Now().Add(dnsResponseCacheTTL(response)),
		}
	}
	delete(r.dnsFlights, key)
	close(call.done)
	r.dnsMu.Unlock()
	return response, queryErr
}

func (r *Router) lookupDoH(ctx context.Context, host string, dialContext func(context.Context, string, string) (net.Conn, error)) ([]net.IP, error) {
	queryTypes := []uint16{1, 28}
	if strings.EqualFold(strings.TrimSpace(r.dns.Strategy), "ipv4_only") {
		queryTypes = []uint16{1}
	}
	var ips []net.IP
	for _, queryType := range queryTypes {
		query := buildDNSQuery(host, queryType)
		data, err := r.exchangeDoHCached(ctx, query, dialContext)
		if err != nil {
			return nil, err
		}
		parsed, err := parseDNSAnswers(data, queryType)
		if err != nil {
			return nil, err
		}
		ips = append(ips, parsed...)
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("doh returned no addresses for %s", host)
	}
	return ips, nil
}

func dnsMessageKey(query []byte) string {
	if len(query) < 12 {
		return ""
	}
	key := append([]byte(nil), query...)
	key[0], key[1] = 0, 0
	return string(key)
}

func dnsResponseForQuery(response, query []byte) []byte {
	if len(response) == 0 {
		return nil
	}
	cloned := append([]byte(nil), response...)
	if len(cloned) >= 2 {
		cloned[0], cloned[1] = 0, 0
		if len(query) >= 2 {
			cloned[0], cloned[1] = query[0], query[1]
		}
	}
	return cloned
}

func dnsResponseCacheable(response []byte) bool {
	if len(response) < 12 {
		return false
	}
	rcode := response[3] & 0x0F
	return rcode == 0 || rcode == 3
}

func dnsResponseCacheTTL(response []byte) time.Duration {
	const fallback = 30 * time.Second
	if len(response) < 12 {
		return fallback
	}
	questions := int(binary.BigEndian.Uint16(response[4:6]))
	records := int(binary.BigEndian.Uint16(response[6:8])) +
		int(binary.BigEndian.Uint16(response[8:10])) +
		int(binary.BigEndian.Uint16(response[10:12]))
	offset := 12
	for index := 0; index < questions; index++ {
		_, next, err := readDNSName(response, offset)
		if err != nil || next+4 > len(response) {
			return fallback
		}
		offset = next + 4
	}
	minimum := 10 * time.Minute
	found := false
	for index := 0; index < records; index++ {
		_, next, err := readDNSName(response, offset)
		if err != nil || next+10 > len(response) {
			return fallback
		}
		ttl := time.Duration(binary.BigEndian.Uint32(response[next+4:next+8])) * time.Second
		length := int(binary.BigEndian.Uint16(response[next+8 : next+10]))
		offset = next + 10 + length
		if offset > len(response) {
			return fallback
		}
		if ttl > 0 && ttl < minimum {
			minimum = ttl
			found = true
		}
	}
	if !found {
		return fallback
	}
	if minimum < fallback {
		return fallback
	}
	if minimum > 10*time.Minute {
		return 10 * time.Minute
	}
	return minimum
}

func buildDNSQuery(host string, qtype uint16) []byte {
	packet := make([]byte, 12)
	binary.BigEndian.PutUint16(packet[0:2], 0x1234)
	binary.BigEndian.PutUint16(packet[2:4], 0x0100) // RD
	binary.BigEndian.PutUint16(packet[4:6], 1)      // QDCOUNT
	host = strings.TrimSuffix(host, ".")
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 {
			continue
		}
		if len(label) > 63 {
			label = label[:63]
		}
		packet = append(packet, byte(len(label)))
		packet = append(packet, label...)
	}
	packet = append(packet, 0)
	packet = binary.BigEndian.AppendUint16(packet, qtype)
	packet = binary.BigEndian.AppendUint16(packet, 1) // IN
	return packet
}

func suppressDNSQuery(strategy string, query []byte) bool {
	queryType, err := dnsQuestionType(query)
	if err != nil {
		return false
	}
	return strategy == "ipv4_only" && queryType == 28 || strategy == "ipv6_only" && queryType == 1
}

func dnsQuestionType(query []byte) (uint16, error) {
	_, queryType, err := dnsQuestion(query)
	return queryType, err
}

func dnsQuestion(query []byte) (string, uint16, error) {
	if len(query) < 12 || binary.BigEndian.Uint16(query[4:6]) == 0 {
		return "", 0, fmt.Errorf("DNS query has no question")
	}
	name, offset, err := readDNSName(query, 12)
	if err != nil || offset+4 > len(query) {
		return "", 0, fmt.Errorf("invalid DNS question")
	}
	return name, binary.BigEndian.Uint16(query[offset : offset+2]), nil
}

func emptyDNSResponse(query []byte) ([]byte, error) {
	return dnsErrorResponse(query, 0)
}

func dnsErrorResponse(query []byte, rcode uint16) ([]byte, error) {
	if len(query) < 12 {
		return nil, fmt.Errorf("DNS query too short")
	}
	response := append([]byte(nil), query...)
	requestFlags := binary.BigEndian.Uint16(response[2:4])
	// Preserve opcode and RD/CD while setting QR and RA with NOERROR.
	responseFlags := uint16(0x8080) | requestFlags&0x0110 | rcode&0x000f
	binary.BigEndian.PutUint16(response[2:4], responseFlags)
	binary.BigEndian.PutUint16(response[6:8], 0)
	binary.BigEndian.PutUint16(response[8:10], 0)
	return response, nil
}

func parseDNSAnswers(data []byte, qtype uint16) ([]net.IP, error) {
	if len(data) < 12 {
		return nil, fmt.Errorf("dns response too short")
	}
	qd := int(binary.BigEndian.Uint16(data[4:6]))
	an := int(binary.BigEndian.Uint16(data[6:8]))
	offset := 12
	for i := 0; i < qd; i++ {
		_, next, err := readDNSName(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next + 4
		if offset > len(data) {
			return nil, fmt.Errorf("dns question overruns packet")
		}
	}
	var ips []net.IP
	for i := 0; i < an; i++ {
		_, next, err := readDNSName(data, offset)
		if err != nil {
			return nil, err
		}
		if next+10 > len(data) {
			return nil, fmt.Errorf("dns answer overruns packet")
		}
		typ := binary.BigEndian.Uint16(data[next : next+2])
		rdlen := int(binary.BigEndian.Uint16(data[next+8 : next+10]))
		rdata := next + 10
		if rdata+rdlen > len(data) {
			return nil, fmt.Errorf("dns rdata overruns packet")
		}
		if typ == qtype && rdlen == net.IPv4len && typ == 1 {
			ips = append(ips, net.IP(append([]byte(nil), data[rdata:rdata+rdlen]...)))
		}
		if typ == qtype && rdlen == net.IPv6len && typ == 28 {
			ips = append(ips, net.IP(append([]byte(nil), data[rdata:rdata+rdlen]...)))
		}
		offset = rdata + rdlen
	}
	return ips, nil
}

type dnsAddressAnswer struct {
	address netip.Addr
	ttl     time.Duration
}

// parseDNSAddressAnswers returns every address carried by a DNS response,
// including additional records. The original question name is deliberately
// associated with all returned addresses because CNAME chains are common for
// Google and YouTube and the application connection only exposes the final IP.
func parseDNSAddressAnswers(data []byte) ([]dnsAddressAnswer, error) {
	if len(data) < 12 {
		return nil, fmt.Errorf("dns response too short")
	}
	qd := int(binary.BigEndian.Uint16(data[4:6]))
	total := int(binary.BigEndian.Uint16(data[6:8])) +
		int(binary.BigEndian.Uint16(data[8:10])) +
		int(binary.BigEndian.Uint16(data[10:12]))
	offset := 12
	for i := 0; i < qd; i++ {
		_, next, err := readDNSName(data, offset)
		if err != nil {
			return nil, err
		}
		offset = next + 4
		if offset > len(data) {
			return nil, fmt.Errorf("dns question overruns packet")
		}
	}

	answers := make([]dnsAddressAnswer, 0, total)
	for i := 0; i < total; i++ {
		_, next, err := readDNSName(data, offset)
		if err != nil {
			return nil, err
		}
		if next+10 > len(data) {
			return nil, fmt.Errorf("dns answer overruns packet")
		}
		typ := binary.BigEndian.Uint16(data[next : next+2])
		class := binary.BigEndian.Uint16(data[next+2 : next+4])
		ttl := time.Duration(binary.BigEndian.Uint32(data[next+4:next+8])) * time.Second
		rdlen := int(binary.BigEndian.Uint16(data[next+8 : next+10]))
		rdata := next + 10
		if rdata+rdlen > len(data) {
			return nil, fmt.Errorf("dns rdata overruns packet")
		}
		if ttl < 30*time.Second {
			ttl = 30 * time.Second
		}
		if ttl > 10*time.Minute {
			ttl = 10 * time.Minute
		}
		if class == 1 && typ == 1 && rdlen == 4 {
			var raw [4]byte
			copy(raw[:], data[rdata:rdata+rdlen])
			answers = append(answers, dnsAddressAnswer{address: netip.AddrFrom4(raw), ttl: ttl})
		}
		if class == 1 && typ == 28 && rdlen == 16 {
			var raw [16]byte
			copy(raw[:], data[rdata:rdata+rdlen])
			answers = append(answers, dnsAddressAnswer{address: netip.AddrFrom16(raw), ttl: ttl})
		}
		offset = rdata + rdlen
	}
	return answers, nil
}

func (r *Router) rememberDNSResponse(query, response []byte) {
	domain, _, err := dnsQuestion(query)
	if err != nil {
		return
	}
	domain = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(domain), "."))
	if domain == "" {
		return
	}
	answers, err := parseDNSAddressAnswers(response)
	if err != nil || len(answers) == 0 {
		return
	}

	now := time.Now()
	ips := make([]net.IP, 0, len(answers))
	expires := now.Add(10 * time.Minute)
	r.dnsMu.Lock()
	defer r.dnsMu.Unlock()
	for _, answer := range answers {
		address := answer.address.Unmap()
		answerExpires := now.Add(answer.ttl)
		if answerExpires.Before(expires) {
			expires = answerExpires
		}
		ips = append(ips, append(net.IP(nil), address.AsSlice()...))

		records := make([]dnsReverseEntry, 0, 8)
		records = append(records, dnsReverseEntry{domain: domain, expires: answerExpires})
		for _, record := range r.dnsReverse[address] {
			if record.domain != domain && record.expires.After(now) {
				records = append(records, record)
				if len(records) == 8 {
					break
				}
			}
		}
		r.dnsReverse[address] = records
	}
	r.dnsCache[domain] = dnsCacheEntry{ips: ips, expires: expires}

	if len(r.dnsReverse) > 8192 {
		for address, records := range r.dnsReverse {
			alive := records[:0]
			for _, record := range records {
				if record.expires.After(now) {
					alive = append(alive, record)
				}
			}
			if len(alive) == 0 {
				delete(r.dnsReverse, address)
			} else {
				r.dnsReverse[address] = alive
			}
		}
	}
}

func (r *Router) domainsForAddress(address netip.Addr) []string {
	address = address.Unmap()
	now := time.Now()
	r.dnsMu.Lock()
	defer r.dnsMu.Unlock()
	records := r.dnsReverse[address]
	if len(records) == 0 {
		return nil
	}
	domains := make([]string, 0, len(records))
	alive := records[:0]
	for _, record := range records {
		if record.expires.After(now) {
			alive = append(alive, record)
			domains = append(domains, record.domain)
		}
	}
	if len(alive) == 0 {
		delete(r.dnsReverse, address)
	} else {
		r.dnsReverse[address] = alive
	}
	return domains
}

func readDNSName(data []byte, offset int) (string, int, error) {
	var labels []string
	pos := offset
	for {
		if pos >= len(data) {
			return "", 0, fmt.Errorf("dns name overruns packet")
		}
		length := int(data[pos])
		if length&0xC0 == 0xC0 {
			if pos+1 >= len(data) {
				return "", 0, fmt.Errorf("dns pointer overruns packet")
			}
			pointer := (length&0x3F)<<8 | int(data[pos+1])
			suffix, _, err := readDNSName(data, pointer)
			if err != nil {
				return "", 0, err
			}
			labels = append(labels, suffix)
			return strings.Join(labels, "."), pos + 2, nil
		}
		pos++
		if length == 0 {
			break
		}
		if pos+length > len(data) {
			return "", 0, fmt.Errorf("dns label overruns packet")
		}
		labels = append(labels, string(data[pos:pos+length]))
		pos += length
	}
	return strings.Join(labels, "."), pos, nil
}
