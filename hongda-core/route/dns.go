package route

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"

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
		encoded := base64.RawURLEncoding.EncodeToString(query)
		q := u.Query()
		q.Set("dns", encoded)
		copyURL := *u
		copyURL.RawQuery = q.Encode()

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, copyURL.String(), nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Accept", "application/dns-message")
		transport := &http.Transport{
			Proxy: nil,
			TLSClientConfig: &tls.Config{
				ServerName: options.TLSServer,
			},
		}
		if dialContext != nil {
			transport.DialContext = dialContext
		}
		client := &http.Client{Transport: transport}
		resp, err := client.Do(req)
		transport.CloseIdleConnections()
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
