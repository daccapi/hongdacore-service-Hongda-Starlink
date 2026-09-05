package protocol

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	quic "github.com/quic-go/quic-go"

	"hongda.local/hongda-core/model"
)

const (
	tuicVersion        = 0x05
	tuicCommandAuth    = 0x00
	tuicCommandConnect = 0x01
	tuicCommandPacket  = 0x02
	tuicCommandDissoc  = 0x03
	tuicCommandBeat    = 0x04

	tuicAtypDomain = 0x00
	tuicAtypIPv4   = 0x01
	tuicAtypIPv6   = 0x02
	tuicAtypNone   = 0xFF

	tuicMaxDatagram = 1200
)

// TUIC implements TUIC protocol version 5 on top of QUIC. It follows the
// public SPEC.md.
type TUIC struct {
	id       string
	server   string
	port     uint16
	uuid     []byte
	uuidStr  string
	password string
	tls      *model.TLSOptions

	mu     sync.Mutex
	sess   *tuicSession
	closed bool
}

type tuicSession struct {
	conn   *quic.Conn
	local  net.Addr
	remote net.Addr
}

func NewTUIC(node model.Node) (*TUIC, error) {
	uuidStr := strings.TrimSpace(node.Auth["uuid"])
	uuidBytes, err := parseUUID(uuidStr)
	if err != nil {
		return nil, fmt.Errorf("tuic: %w", err)
	}
	password := node.Auth["password"]
	if password == "" {
		return nil, fmt.Errorf("tuic password is required")
	}
	return &TUIC{
		id:       node.ID,
		server:   node.Server,
		port:     node.Port,
		uuid:     uuidBytes,
		uuidStr:  uuidStr,
		password: password,
		tls:      node.TLS,
	}, nil
}

func (t *TUIC) ID() string               { return t.id }
func (t *TUIC) Type() model.ProtocolType { return model.ProtocolTUIC }
func (t *TUIC) SupportUDP() bool         { return true }

func (t *TUIC) Close() error {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closed = true
	if t.sess != nil {
		_ = t.sess.conn.CloseWithError(0, "client closed")
		t.sess = nil
	}
	return nil
}

func (t *TUIC) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	switch network {
	case "tcp":
		return t.dialTCP(ctx, address)
	case "udp":
		return t.dialUDP(ctx, address)
	default:
		return nil, fmt.Errorf("tuic supports tcp and udp only")
	}
}

func (t *TUIC) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	conn, err := t.DialContext(ctx, "udp", address)
	if err != nil {
		return nil, err
	}
	return &udpConnPacketConn{Conn: conn}, nil
}

func (t *TUIC) dialTCP(ctx context.Context, address string) (net.Conn, error) {
	sess, err := t.session(ctx)
	if err != nil {
		return nil, err
	}
	stream, err := sess.conn.OpenStreamSync(ctx)
	if err != nil {
		return nil, err
	}
	if err := writeTUICConnect(stream, address); err != nil {
		_ = stream.Close()
		return nil, err
	}
	return &tuicStreamConn{
		Stream: stream,
		local:  sess.local,
		remote: sess.remote,
	}, nil
}

func (t *TUIC) dialUDP(ctx context.Context, address string) (net.Conn, error) {
	sess, err := t.dialSession(ctx)
	if err != nil {
		return nil, err
	}
	return &tuicUDPConn{
		conn:      sess.conn,
		local:     sess.local,
		remote:    sess.remote,
		assocID:   randomUint16(),
		target:    address,
		fragments: make(map[uint16][][]byte),
		fragCount: make(map[uint16]int),
	}, nil
}

func (t *TUIC) session(ctx context.Context) (*tuicSession, error) {
	t.mu.Lock()
	if t.closed {
		t.mu.Unlock()
		return nil, net.ErrClosed
	}
	if t.sess != nil {
		s := t.sess
		t.mu.Unlock()
		return s, nil
	}
	t.mu.Unlock()

	sess, err := t.dialSession(ctx)
	if err != nil {
		return nil, err
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		_ = sess.conn.CloseWithError(0, "client closed")
		return nil, net.ErrClosed
	}
	if t.sess == nil {
		t.sess = sess
	} else {
		_ = sess.conn.CloseWithError(0, "duplicate session")
		sess = t.sess
	}
	return sess, nil
}

func (t *TUIC) dialSession(ctx context.Context) (*tuicSession, error) {
	serverName := t.server
	if t.tls != nil && t.tls.ServerName != "" {
		serverName = t.tls.ServerName
	}
	insecure := t.tls != nil && t.tls.Insecure
	tlsCfg := &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: insecure,
		NextProtos:         []string{"h3"},
	}
	quicCfg := &quic.Config{
		EnableDatagrams: true,
		KeepAlivePeriod: 30 * time.Second,
		MaxIdleTimeout:  300 * time.Second,
	}
	addr := net.JoinHostPort(t.server, strconv.Itoa(int(t.port)))
	conn, err := quic.DialAddr(ctx, addr, tlsCfg, quicCfg)
	if err != nil {
		return nil, fmt.Errorf("tuic: dial quic: %w", err)
	}
	stream, err := conn.OpenUniStreamSync(ctx)
	if err != nil {
		_ = conn.CloseWithError(1, "open auth stream failed")
		return nil, err
	}
	if err := t.writeAuthenticate(conn, stream); err != nil {
		_ = conn.CloseWithError(1, "auth failed")
		return nil, err
	}
	_ = stream.Close()
	return &tuicSession{conn: conn, local: conn.LocalAddr(), remote: conn.RemoteAddr()}, nil
}

func (t *TUIC) writeAuthenticate(conn *quic.Conn, w io.Writer) error {
	state := conn.ConnectionState().TLS
	token, err := state.ExportKeyingMaterial(t.uuidStr, []byte(t.password), 32)
	if err != nil {
		return fmt.Errorf("tuic: export keying material: %w", err)
	}
	buf := make([]byte, 0, 1+1+16+32)
	buf = append(buf, tuicVersion, tuicCommandAuth)
	buf = append(buf, t.uuid...)
	buf = append(buf, token...)
	if _, err := w.Write(buf); err != nil {
		return fmt.Errorf("tuic: write authenticate: %w", err)
	}
	return nil
}

func writeTUICConnect(w io.Writer, address string) error {
	addrBytes, err := tuicAddress(address)
	if err != nil {
		return err
	}
	buf := make([]byte, 0, 2+len(addrBytes))
	buf = append(buf, tuicVersion, tuicCommandConnect)
	buf = append(buf, addrBytes...)
	if _, err := w.Write(buf); err != nil {
		return fmt.Errorf("tuic: write connect: %w", err)
	}
	return nil
}

func tuicAddress(address string) ([]byte, error) {
	host, port, err := splitAddress(address)
	if err != nil {
		return nil, err
	}
	out := make([]byte, 0, 1+len(host)+2+1)
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			out = append(out, tuicAtypIPv4)
			out = append(out, v4...)
		} else {
			out = append(out, tuicAtypIPv6)
			out = append(out, ip.To16()...)
		}
	} else {
		if len(host) > 255 {
			return nil, fmt.Errorf("tuic: domain name is too long")
		}
		out = append(out, tuicAtypDomain, byte(len(host)))
		out = append(out, host...)
	}
	out = append(out, byte(port>>8), byte(port))
	return out, nil
}

type tuicStreamConn struct {
	*quic.Stream
	local  net.Addr
	remote net.Addr
}

func (c *tuicStreamConn) LocalAddr() net.Addr  { return c.local }
func (c *tuicStreamConn) RemoteAddr() net.Addr { return c.remote }

type tuicUDPConn struct {
	conn      *quic.Conn
	local     net.Addr
	remote    net.Addr
	assocID   uint16
	target    string
	packetID  uint16
	readBuf   []byte
	mu        sync.Mutex
	fragments map[uint16][][]byte
	fragCount map[uint16]int
}

func (c *tuicUDPConn) LocalAddr() net.Addr  { return c.local }
func (c *tuicUDPConn) RemoteAddr() net.Addr { return c.remote }

func (c *tuicUDPConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for {
		if len(c.readBuf) > 0 {
			n := copy(p, c.readBuf)
			c.readBuf = c.readBuf[n:]
			return n, nil
		}
		datagram, err := c.conn.ReceiveDatagram(context.Background())
		if err != nil {
			return 0, err
		}
		payload, ok := c.handleIncomingDatagram(datagram)
		if !ok || len(payload) == 0 {
			continue
		}
		n := copy(p, payload)
		c.readBuf = payload[n:]
		return n, nil
	}
}

func (c *tuicUDPConn) handleIncomingDatagram(data []byte) ([]byte, bool) {
	header, payload, err := parseTUICPacket(data)
	if err != nil || header.assocID != c.assocID || header.fragTotal == 0 {
		return nil, false
	}
	if header.fragTotal == 1 {
		return payload, true
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.fragments[header.packetID] == nil {
		c.fragments[header.packetID] = make([][]byte, int(header.fragTotal))
		c.fragCount[header.packetID] = 0
	}
	if int(header.fragID) >= len(c.fragments[header.packetID]) {
		return nil, false
	}
	if c.fragments[header.packetID][header.fragID] == nil {
		c.fragments[header.packetID][header.fragID] = append([]byte(nil), payload...)
		c.fragCount[header.packetID]++
	}
	if c.fragCount[header.packetID] == int(header.fragTotal) {
		var full []byte
		for _, part := range c.fragments[header.packetID] {
			full = append(full, part...)
		}
		delete(c.fragments, header.packetID)
		delete(c.fragCount, header.packetID)
		return full, true
	}
	return nil, false
}

func (c *tuicUDPConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.packetID++
	chunkSize := tuicMaxDatagram - 13 - len(c.target)
	if chunkSize < 1 {
		return 0, fmt.Errorf("tuic: target address is too long")
	}
	if len(p) <= chunkSize {
		if err := c.sendPacket(c.packetID, 0, 1, p); err != nil {
			return 0, err
		}
		return len(p), nil
	}
	count := (len(p) + chunkSize - 1) / chunkSize
	if count > 255 {
		return 0, fmt.Errorf("tuic: udp packet requires %d fragments, max 255", count)
	}
	for i := 0; i < count; i++ {
		start := i * chunkSize
		end := start + chunkSize
		if end > len(p) {
			end = len(p)
		}
		if err := c.sendPacket(c.packetID, uint8(i), uint8(count), p[start:end]); err != nil {
			return start, err
		}
	}
	return len(p), nil
}

func (c *tuicUDPConn) sendPacket(packetID uint16, fragID, fragTotal uint8, payload []byte) error {
	buf := make([]byte, 0, 32+len(payload))
	buf = append(buf, tuicVersion, tuicCommandPacket)
	buf = binary.BigEndian.AppendUint16(buf, c.assocID)
	buf = binary.BigEndian.AppendUint16(buf, packetID)
	buf = append(buf, fragTotal, fragID)
	buf = binary.BigEndian.AppendUint16(buf, uint16(len(payload)))
	if fragID == 0 {
		addrBytes, err := tuicAddress(c.target)
		if err != nil {
			return err
		}
		buf = append(buf, addrBytes...)
	} else {
		buf = append(buf, tuicAtypNone)
	}
	buf = append(buf, payload...)
	return c.conn.SendDatagram(buf)
}

func (c *tuicUDPConn) Close() error {
	return c.conn.CloseWithError(0, "udp session closed")
}

func (c *tuicUDPConn) SetDeadline(time.Time) error      { return nil }
func (c *tuicUDPConn) SetReadDeadline(time.Time) error  { return nil }
func (c *tuicUDPConn) SetWriteDeadline(time.Time) error { return nil }

type tuicPacketHeader struct {
	assocID   uint16
	packetID  uint16
	fragTotal uint8
	fragID    uint8
}

func parseTUICPacket(data []byte) (tuicPacketHeader, []byte, error) {
	var hdr tuicPacketHeader
	if len(data) < 2 || data[0] != tuicVersion || data[1] != tuicCommandPacket {
		return hdr, nil, fmt.Errorf("tuic: invalid packet command")
	}
	if len(data) < 10 {
		return hdr, nil, io.ErrUnexpectedEOF
	}
	hdr.assocID = binary.BigEndian.Uint16(data[2:4])
	hdr.packetID = binary.BigEndian.Uint16(data[4:6])
	hdr.fragTotal = data[6]
	hdr.fragID = data[7]
	size := int(binary.BigEndian.Uint16(data[8:10]))
	addrEnd := 10
	if hdr.fragID == 0 {
		_, consumed, err := parseTUICAddress(data[10:])
		if err != nil {
			return hdr, nil, err
		}
		addrEnd = 10 + consumed
	} else {
		if len(data) < 11 {
			return hdr, nil, io.ErrUnexpectedEOF
		}
		if data[10] != tuicAtypNone {
			return hdr, nil, fmt.Errorf("tuic: non-first fragment must use address type none")
		}
		addrEnd = 11
	}
	payloadEnd := addrEnd + size
	if payloadEnd > len(data) {
		return hdr, nil, io.ErrUnexpectedEOF
	}
	return hdr, data[addrEnd:payloadEnd], nil
}

func parseTUICAddress(data []byte) (string, int, error) {
	if len(data) < 1 {
		return "", 0, io.ErrUnexpectedEOF
	}
	typ := data[0]
	var host string
	consumed := 1
	switch typ {
	case tuicAtypDomain:
		if len(data) < 2 {
			return "", 0, io.ErrUnexpectedEOF
		}
		n := int(data[1])
		if len(data) < 2+n+2 {
			return "", 0, io.ErrUnexpectedEOF
		}
		host = string(data[2 : 2+n])
		consumed = 2 + n + 2
	case tuicAtypIPv4:
		if len(data) < 1+4+2 {
			return "", 0, io.ErrUnexpectedEOF
		}
		host = net.IP(data[1:5]).String()
		consumed = 1 + 4 + 2
	case tuicAtypIPv6:
		if len(data) < 1+16+2 {
			return "", 0, io.ErrUnexpectedEOF
		}
		host = net.IP(data[1:17]).String()
		consumed = 1 + 16 + 2
	case tuicAtypNone:
		consumed = 1
	default:
		return "", 0, fmt.Errorf("tuic: unknown address type %#x", typ)
	}
	if typ == tuicAtypNone {
		return "", consumed, nil
	}
	port := int(binary.BigEndian.Uint16(data[consumed-2 : consumed]))
	return net.JoinHostPort(host, strconv.Itoa(port)), consumed, nil
}

func randomUint16() uint16 {
	var b [2]byte
	if _, err := rand.Read(b[:]); err != nil {
		return uint16(time.Now().UnixNano())
	}
	return binary.BigEndian.Uint16(b[:])
}

var _ model.Outbound = (*TUIC)(nil)
