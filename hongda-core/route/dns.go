package route

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
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
	storedAt time.Time
}

type dnsMessageCall struct {
	done     chan struct{}
	response []byte
	err      error
}

// dnsCacheScope separates resolvers, DNS strategies and actual selector nodes.
func (r *Router) dnsCacheScope() string {
	return r.dnsScopeForTarget(r.dnsTarget())
}

func (r *Router) dnsTarget() string {
	target := r.dns.Detour
	if target == "" {
		target = "direct"
	}
	return r.resolve(target)
}

func (r *Router) dnsScopeForTarget(target string) string {
	data, _ := json.Marshal(struct {
		DNS    model.DNSOptions
		Target string
	}{r.dns, target})
	hash := sha256.Sum256(data)
	return hex.EncodeToString(hash[:])
}

// InvalidateDNSConnections is called after explicit selector changes. Automatic
// URLTest switches are also detected when the next DNS request acquires a pool.
func (r *Router) InvalidateDNSConnections() {
	r.dohMu.Lock()
	defer r.dohMu.Unlock()
	if r.dohCancel != nil {
		r.dohCancel()
	}
	if r.dohTransport != nil {
		r.dohTransport.CloseIdleConnections()
	}
	r.dohClient = nil
	r.dohTransport = nil
}

func (r *Router) dohHTTPClient(scope, target string) (*http.Client, context.Context, error) {
	r.dohMu.Lock()
	defer r.dohMu.Unlock()
	if r.dohClient != nil && r.dohScope == scope {
		return r.dohClient, r.dohContext, nil
	}
	if r.dohCancel != nil {
		r.dohCancel()
	}
	if r.dohTransport != nil {
		r.dohTransport.CloseIdleConnections()
	}
	r.dohClient = nil
	r.dohTransport = nil
	var dial func(context.Context, string, string) (net.Conn, error)
	if outbound, ok := r.outbounds[target]; ok {
		dial = outbound.DialContext
	} else if target != "direct" {
		return nil, nil, errUnknownOutbound(target)
	}
	transport := newDoHTransport(r.dns, dial)
	r.dohTransport = transport
	r.dohClient = &http.Client{Transport: transport}
	r.dohContext, r.dohCancel = context.WithCancel(context.Background())
	r.dohScope = scope
	return r.dohClient, r.dohContext, nil
}

func (r *Router) exchangeDoHCached(ctx context.Context, query []byte) ([]byte, error) {
	target := r.dnsTarget()
	scope := r.dnsScopeForTarget(target)
	client, poolContext, err := r.dohHTTPClient(scope, target)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	stopPoolCancel := context.AfterFunc(poolContext, cancel)
	defer stopPoolCancel()
	defer cancel()

	wireKey := dnsMessageKey(query)
	if wireKey == "" {
		return nil, fmt.Errorf("invalid DNS question")
	}
	key := scope + wireKey
	now := time.Now()
	r.dnsMu.Lock()
	if cached, ok := r.dnsMessages[key]; ok && now.Before(cached.expires) {
		response := ageDNSResponse(cached.response, query, now.Sub(cached.storedAt))
		r.dnsMu.Unlock()
		r.rememberDNSResponseScoped(query, response, scope)
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
		response, queryErr = exchangeDoHURLWithClient(ctx, client, u, query)
	}
	if poolContext.Err() != nil {
		queryErr = context.Canceled
	}
	stored := dnsResponseForQuery(response, nil)
	ttl := dnsResponseCacheTTL(response)
	r.dnsMu.Lock()
	call.response = stored
	call.err = queryErr
	if queryErr == nil && ttl > 0 && dnsResponseCacheable(response) {
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
		now = time.Now()
		r.dnsMessages[key] = dnsMessageCacheEntry{
			response: stored, storedAt: now, expires: now.Add(ttl),
		}
		r.dnsPersistDirty = true
	}
	delete(r.dnsFlights, key)
	close(call.done)
	r.dnsMu.Unlock()
	if queryErr == nil {
		r.rememberDNSResponseScoped(query, response, scope)
	}
	return response, queryErr
}

func (r *Router) lookupDoH(ctx context.Context, host string) ([]net.IP, error) {
	queryTypes := []uint16{1, 28}
	if r.dns.Strategy == "ipv4_only" {
		queryTypes = []uint16{1}
	}
	if r.dns.Strategy == "ipv6_only" {
		queryTypes = []uint16{28}
	}
	var ips []net.IP
	for _, queryType := range queryTypes {
		data, err := r.exchangeDoHCached(ctx, buildDNSQuery(host, queryType))
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
	if len(response) < 12 || response[2]&0x80 == 0 || response[2]&0x02 != 0 {
		return false
	}
	rcode := response[3] & 0x0F
	return rcode == 0 || rcode == 3
}

type dnsWireRecord struct {
	typ        uint16
	ttlOffset  int
	dataOffset int
	end        int
}

// walkDNSRecords validates message boundaries before caching or aging records.
func walkDNSRecords(data []byte) ([]dnsWireRecord, error) {
	if len(data) < 12 {
		return nil, fmt.Errorf("DNS header too short")
	}
	offset := 12
	for i := 0; i < int(binary.BigEndian.Uint16(data[4:6])); i++ {
		_, next, err := readDNSName(data, offset)
		if err != nil || next+4 > len(data) {
			return nil, fmt.Errorf("invalid DNS question")
		}
		offset = next + 4
	}
	count := int(binary.BigEndian.Uint16(data[6:8])) + int(binary.BigEndian.Uint16(data[8:10])) + int(binary.BigEndian.Uint16(data[10:12]))
	records := make([]dnsWireRecord, 0)
	for i := 0; i < count; i++ {
		_, next, err := readDNSName(data, offset)
		if err != nil || next+10 > len(data) {
			return nil, fmt.Errorf("invalid DNS record")
		}
		end := next + 10 + int(binary.BigEndian.Uint16(data[next+8:next+10]))
		if end > len(data) {
			return nil, fmt.Errorf("DNS record exceeds packet")
		}
		records = append(records, dnsWireRecord{binary.BigEndian.Uint16(data[next : next+2]), next + 4, next + 10, end})
		offset = end
	}
	return records, nil
}

func dnsResponseCacheTTL(response []byte) time.Duration {
	if !dnsResponseCacheable(response) {
		return 0
	}
	records, err := walkDNSRecords(response)
	if err != nil {
		return 0
	}
	negative := binary.BigEndian.Uint16(response[6:8]) == 0 || response[3]&0x0f == 3
	minimum := 10 * time.Minute
	found := false
	for _, record := range records {
		if record.typ == 41 {
			continue
		} // EDNS OPT's field is flags, not a TTL.
		ttl := time.Duration(binary.BigEndian.Uint32(response[record.ttlOffset:record.ttlOffset+4])) * time.Second
		if negative {
			if record.typ != 6 {
				continue
			} // RFC 2308: negative answers need SOA.
			_, next, e := readDNSName(response, record.dataOffset)
			if e != nil {
				return 0
			}
			_, next, e = readDNSName(response, next)
			if e != nil || next+20 != record.end {
				return 0
			}
			soaMinimum := time.Duration(binary.BigEndian.Uint32(response[next+16:next+20])) * time.Second
			if soaMinimum < ttl {
				ttl = soaMinimum
			}
		}
		found = true
		if ttl < minimum {
			minimum = ttl
		}
	}
	if !found {
		return 0
	}
	return minimum
}

func ageDNSResponse(response, query []byte, elapsed time.Duration) []byte {
	cloned := dnsResponseForQuery(response, query)
	records, err := walkDNSRecords(cloned)
	if err != nil {
		return nil
	}
	seconds := uint64(max(elapsed/time.Second, 0))
	for _, record := range records {
		if record.typ == 41 {
			continue
		}
		ttl := uint64(binary.BigEndian.Uint32(cloned[record.ttlOffset : record.ttlOffset+4]))
		if seconds >= ttl {
			ttl = 0
		} else {
			ttl -= seconds
		}
		binary.BigEndian.PutUint32(cloned[record.ttlOffset:record.ttlOffset+4], uint32(ttl))
	}
	return cloned
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
	r.rememberDNSResponseScoped(query, response, r.dnsCacheScope())
}

func (r *Router) rememberDNSResponseScoped(query, response []byte, scope string) {
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
	responseTTL := dnsResponseCacheTTL(response)
	if responseTTL <= 0 {
		return
	}

	now := time.Now()
	ips := make([]net.IP, 0, len(answers))
	expires := now.Add(10 * time.Minute)
	r.dnsMu.Lock()
	defer r.dnsMu.Unlock()
	for _, answer := range answers {
		answer.ttl = min(answer.ttl, responseTTL)
		if answer.ttl <= 0 {
			continue
		}
		address := answer.address.Unmap()
		answerExpires := now.Add(answer.ttl)
		if answerExpires.Before(expires) {
			expires = answerExpires
		}
		ips = append(ips, append(net.IP(nil), address.AsSlice()...))

		records := make([]dnsReverseEntry, 0, 8)
		records = append(records, dnsReverseEntry{domain: domain, expires: answerExpires, scope: scope})
		for _, record := range r.dnsReverse[address] {
			if (record.domain != domain || record.scope != scope) && record.expires.After(now) {
				records = append(records, record)
				if len(records) == 8 {
					break
				}
			}
		}
		r.dnsReverse[address] = records
	}
	if len(ips) > 0 {
		if len(r.dnsCache) >= 4096 {
			for key := range r.dnsCache {
				delete(r.dnsCache, key)
				break
			}
		}
		r.dnsCache[scope+domain] = dnsCacheEntry{ips: ips, expires: expires}
	}

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
	scope := r.dnsCacheScope()
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
			if record.scope == scope {
				domains = append(domains, record.domain)
			}
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
	pos, next, total := offset, -1, 1
	visited := make(map[int]bool)
	for hops := 0; hops < 256; hops++ {
		if pos < 0 || pos >= len(data) {
			return "", 0, fmt.Errorf("dns name overruns packet")
		}
		if visited[pos] {
			return "", 0, fmt.Errorf("dns compression pointer cycle")
		}
		visited[pos] = true
		length := int(data[pos])
		if length&0xc0 == 0xc0 {
			if pos+1 >= len(data) {
				return "", 0, fmt.Errorf("dns pointer overruns packet")
			}
			if next < 0 {
				next = pos + 2
			}
			pos = (length&0x3f)<<8 | int(data[pos+1])
			continue
		}
		if length&0xc0 != 0 {
			return "", 0, fmt.Errorf("invalid DNS label type")
		}
		pos++
		if length == 0 {
			if next < 0 {
				next = pos
			}
			return strings.Join(labels, "."), next, nil
		}
		if pos+length > len(data) {
			return "", 0, fmt.Errorf("dns label overruns packet")
		}
		total += length + 1
		if total > 255 {
			return "", 0, fmt.Errorf("dns name exceeds 255 bytes")
		}
		labels = append(labels, string(data[pos:pos+length]))
		pos += length
	}
	return "", 0, fmt.Errorf("dns pointer hop limit exceeded")
}
