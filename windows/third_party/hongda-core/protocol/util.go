package protocol

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"net"
	"strconv"
	"strings"

	"hongda.local/hongda-core/model"
)

func splitAddress(address string) (host string, port uint16, err error) {
	h, p, err := net.SplitHostPort(address)
	if err != nil {
		return "", 0, err
	}
	n, err := strconv.Atoi(p)
	if err != nil || n < 1 || n > 65535 {
		return "", 0, fmt.Errorf("invalid port %q", p)
	}
	return h, uint16(n), nil
}

// dialTLSDirect connects to host:port and, when TLS is enabled, performs a
// standard TLS handshake. Reality/uTLS are implemented in a later phase.
func dialTLSDirect(ctx context.Context, host string, port uint16, tlsOpts *model.TLSOptions) (net.Conn, error) {
	addr := net.JoinHostPort(host, strconv.Itoa(int(port)))
	var d net.Dialer
	conn, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	if tlsOpts == nil || !tlsOpts.Enabled {
		return conn, nil
	}
	serverName := tlsOpts.ServerName
	if serverName == "" {
		serverName = host
	}
	cfg := &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: tlsOpts.Insecure,
		NextProtos:         []string{"http/1.1"},
	}
	tlsConn := tls.Client(conn, cfg)
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return tlsConn, nil
}

// parseUUID converts a hyphenated UUID string into its 16-byte form.
func parseUUID(s string) ([]byte, error) {
	clean := strings.ReplaceAll(strings.TrimSpace(s), "-", "")
	if len(clean) != 32 {
		return nil, fmt.Errorf("invalid uuid %q", s)
	}
	b, err := hex.DecodeString(clean)
	if err != nil {
		return nil, fmt.Errorf("invalid uuid %q: %w", s, err)
	}
	return b, nil
}

// vlessAddress encodes the destination in VLESS wire order:
// port(2) + address-type(1) + address.
func vlessAddress(host string, port uint16) []byte {
	buf := []byte{byte(port >> 8), byte(port)}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			buf = append(buf, 0x01)
			buf = append(buf, v4...)
		} else {
			buf = append(buf, 0x03)
			buf = append(buf, ip.To16()...)
		}
		return buf
	}
	buf = append(buf, 0x02, byte(len(host)))
	buf = append(buf, host...)
	return buf
}

// trojanAddress encodes the destination in Trojan wire order:
// address-type(1) + address + port(2).
func trojanAddress(host string, port uint16) []byte {
	var buf []byte
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			buf = append(buf, 0x01)
			buf = append(buf, v4...)
		} else {
			buf = append(buf, 0x04)
			buf = append(buf, ip.To16()...)
		}
	} else {
		buf = append(buf, 0x03, byte(len(host)))
		buf = append(buf, host...)
	}
	buf = append(buf, byte(port>>8), byte(port))
	return buf
}
