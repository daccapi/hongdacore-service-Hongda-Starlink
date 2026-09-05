package protocol

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	quic "github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"github.com/quic-go/quic-go/quicvarint"

	"hongda.local/hongda-core/model"
)

const (
	hysteria2FrameTCPRequest = 0x401
	hysteria2AuthPath        = "/auth"
	hysteria2AuthHost        = "hysteria"
	hysteria2StatusOK        = 233
	hysteria2MaxDatagram     = 1200
)

// Hysteria2 implements the Hysteria 2 client wire protocol on top of QUIC.
// The framing is implemented from the public protocol specification.
type Hysteria2 struct {
	id           string
	server       string
	port         uint16
	password     string
	obfsPassword string
	tls          *model.TLSOptions

	mu     sync.Mutex
	sess   *hysteria2Session
	closed bool
}

type hysteria2Session struct {
	conn       *quic.Conn
	http       *http3.ClientConn
	transport  *http3.Transport
	packetConn net.PacketConn
	local      net.Addr
	remote     net.Addr
}

func NewHysteria2(node model.Node) (*Hysteria2, error) {
	password := node.Auth["password"]
	if password == "" {
		return nil, fmt.Errorf("hysteria2 password is required")
	}
	return &Hysteria2{
		id:           node.ID,
		server:       node.Server,
		port:         node.Port,
		password:     password,
		obfsPassword: node.Auth["obfs_password"],
		tls:          node.TLS,
	}, nil
}

func (h *Hysteria2) ID() string               { return h.id }
func (h *Hysteria2) Type() model.ProtocolType { return model.ProtocolHysteria2 }
func (h *Hysteria2) SupportUDP() bool         { return true }

func (h *Hysteria2) Close() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	if h.sess != nil {
		h.sess.close(0, "client closed")
		h.sess = nil
	}
	return nil
}

func (h *Hysteria2) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	switch network {
	case "tcp":
		return h.dialTCP(ctx, address)
	case "udp":
		return h.dialUDP(ctx, address)
	default:
		return nil, fmt.Errorf("hysteria2 supports tcp and udp only")
	}
}

func (h *Hysteria2) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	conn, err := h.DialContext(ctx, "udp", address)
	if err != nil {
		return nil, err
	}
	return &udpConnPacketConn{Conn: conn}, nil
}

func (h *Hysteria2) dialTCP(ctx context.Context, address string) (net.Conn, error) {
	sess, err := h.session(ctx)
	if err != nil {
		return nil, err
	}
	stream, err := sess.conn.OpenStreamSync(ctx)
	if err != nil {
		return nil, err
	}
	if err := writeHysteria2TCPRequest(stream, address); err != nil {
		_ = stream.Close()
		return nil, err
	}
	reader := bufio.NewReader(stream)
	if err := readHysteria2TCPResponse(reader); err != nil {
		_ = stream.Close()
		return nil, err
	}
	return &hysteria2StreamConn{
		Stream: stream,
		local:  sess.local,
		remote: sess.remote,
		reader: reader,
	}, nil
}

func (h *Hysteria2) dialUDP(ctx context.Context, address string) (net.Conn, error) {
	sess, err := h.dialSession(ctx)
	if err != nil {
		return nil, err
	}
	sessionID := randomUint32()
	return &hysteria2UDPConn{
		conn:       sess.conn,
		packetConn: sess.packetConn,
		local:      sess.local,
		remote:     sess.remote,
		sessionID:  sessionID,
		target:     address,
	}, nil
}

func (h *Hysteria2) session(ctx context.Context) (*hysteria2Session, error) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return nil, net.ErrClosed
	}
	if h.sess != nil {
		s := h.sess
		h.mu.Unlock()
		return s, nil
	}
	h.mu.Unlock()

	sess, err := h.dialSession(ctx)
	if err != nil {
		return nil, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		sess.close(0, "client closed")
		return nil, net.ErrClosed
	}
	if h.sess == nil {
		h.sess = sess
	} else {
		sess.close(0, "duplicate session")
		sess = h.sess
	}
	return sess, nil
}

func (h *Hysteria2) dialSession(ctx context.Context) (*hysteria2Session, error) {
	serverName := h.server
	if h.tls != nil && h.tls.ServerName != "" {
		serverName = h.tls.ServerName
	}
	insecure := h.tls != nil && h.tls.Insecure
	tlsCfg := &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: insecure,
		NextProtos:         []string{http3.NextProtoH3},
	}
	quicCfg := &quic.Config{
		EnableDatagrams: true,
		KeepAlivePeriod: 30 * time.Second,
		MaxIdleTimeout:  300 * time.Second,
	}
	addr := net.JoinHostPort(h.server, strconv.Itoa(int(h.port)))
	conn, packetConn, err := h.dialQUIC(ctx, addr, tlsCfg, quicCfg)
	if err != nil {
		return nil, fmt.Errorf("hysteria2: dial quic: %w", err)
	}
	transport := &http3.Transport{}
	client := transport.NewClientConn(conn)
	if err := hysteria2Auth(ctx, client, addr, h.password); err != nil {
		_ = conn.CloseWithError(1, "auth failed")
		if packetConn != nil {
			_ = packetConn.Close()
		}
		return nil, err
	}
	return &hysteria2Session{
		conn:       conn,
		http:       client,
		transport:  transport,
		packetConn: packetConn,
		local:      conn.LocalAddr(),
		remote:     conn.RemoteAddr(),
	}, nil
}

func (h *Hysteria2) dialQUIC(
	ctx context.Context,
	addr string,
	tlsCfg *tls.Config,
	quicCfg *quic.Config,
) (*quic.Conn, net.PacketConn, error) {
	if h.obfsPassword == "" {
		conn, err := quic.DialAddr(ctx, addr, tlsCfg, quicCfg)
		return conn, nil, err
	}
	remote, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, nil, err
	}
	network := "udp4"
	local := &net.UDPAddr{IP: net.IPv4zero, Port: 0}
	if remote.IP.To4() == nil {
		network = "udp6"
		local = &net.UDPAddr{IP: net.IPv6unspecified, Port: 0}
	}
	udpConn, err := net.ListenUDP(network, local)
	if err != nil {
		return nil, nil, err
	}
	packetConn, err := newSalamanderPacketConn(udpConn, h.obfsPassword)
	if err != nil {
		_ = udpConn.Close()
		return nil, nil, err
	}
	conn, err := quic.Dial(ctx, packetConn, remote, tlsCfg, quicCfg)
	if err != nil {
		_ = packetConn.Close()
		return nil, nil, err
	}
	return conn, packetConn, nil
}

func (s *hysteria2Session) close(code quic.ApplicationErrorCode, message string) {
	_ = s.conn.CloseWithError(code, message)
	if s.packetConn != nil {
		_ = s.packetConn.Close()
	}
}

func hysteria2Auth(ctx context.Context, client *http3.ClientConn, addr, password string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://"+addr+hysteria2AuthPath, nil)
	if err != nil {
		return err
	}
	req.Host = hysteria2AuthHost
	req.Header.Set("Hysteria-Auth", password)
	req.Header.Set("Hysteria-CC-RX", "0")
	req.Header.Set("Hysteria-Padding", randomPadding(64, 128))
	resp, err := client.RoundTrip(req)
	if err != nil {
		return fmt.Errorf("hysteria2: auth request: %w", err)
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != hysteria2StatusOK {
		return fmt.Errorf("hysteria2: authentication rejected with status %d", resp.StatusCode)
	}
	return nil
}

func writeHysteria2TCPRequest(w io.Writer, address string) error {
	buf := make([]byte, 0, len(address)+16)
	buf = quicvarint.Append(buf, hysteria2FrameTCPRequest)
	buf = quicvarint.Append(buf, uint64(len(address)))
	buf = append(buf, address...)
	buf = quicvarint.Append(buf, 0)
	if _, err := w.Write(buf); err != nil {
		return fmt.Errorf("hysteria2: write tcp request: %w", err)
	}
	return nil
}

func readHysteria2TCPResponse(r *bufio.Reader) error {
	var status [1]byte
	if _, err := io.ReadFull(r, status[:]); err != nil {
		return fmt.Errorf("hysteria2: read tcp response status: %w", err)
	}
	if status[0] != 0x00 {
		msgLen, err := quicvarint.Read(r)
		if err != nil {
			return fmt.Errorf("hysteria2: read tcp error message length: %w", err)
		}
		if msgLen > 0 {
			if _, err := io.CopyN(io.Discard, r, int64(msgLen)); err != nil {
				return fmt.Errorf("hysteria2: discard tcp error message: %w", err)
			}
		}
		return fmt.Errorf("hysteria2: tcp connect failed with status %d", status[0])
	}
	msgLen, err := quicvarint.Read(r)
	if err != nil {
		return fmt.Errorf("hysteria2: read tcp response message length: %w", err)
	}
	if msgLen > 0 {
		if _, err := io.CopyN(io.Discard, r, int64(msgLen)); err != nil {
			return fmt.Errorf("hysteria2: discard tcp response message: %w", err)
		}
	}
	paddingLen, err := quicvarint.Read(r)
	if err != nil {
		return fmt.Errorf("hysteria2: read tcp response padding length: %w", err)
	}
	if paddingLen > 0 {
		if _, err := io.CopyN(io.Discard, r, int64(paddingLen)); err != nil {
			return fmt.Errorf("hysteria2: discard tcp response padding: %w", err)
		}
	}
	return nil
}

type hysteria2StreamConn struct {
	*quic.Stream
	local  net.Addr
	remote net.Addr
	reader *bufio.Reader
}

func (c *hysteria2StreamConn) LocalAddr() net.Addr  { return c.local }
func (c *hysteria2StreamConn) RemoteAddr() net.Addr { return c.remote }

func (c *hysteria2StreamConn) Read(p []byte) (int, error) {
	if c.reader != nil {
		return c.reader.Read(p)
	}
	return c.Stream.Read(p)
}

type hysteria2UDPConn struct {
	conn       *quic.Conn
	packetConn net.PacketConn
	local      net.Addr
	remote     net.Addr
	sessionID  uint32
	target     string
	packetID   atomic.Uint32
	readBuf    []byte

	fragMu     sync.Mutex
	fragments  map[uint16][][]byte
	fragCounts map[uint16]int
}

func (c *hysteria2UDPConn) LocalAddr() net.Addr  { return c.local }
func (c *hysteria2UDPConn) RemoteAddr() net.Addr { return c.remote }

func (c *hysteria2UDPConn) Read(p []byte) (int, error) {
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

func (c *hysteria2UDPConn) handleIncomingDatagram(data []byte) ([]byte, bool) {
	header, addrBytes, payload, err := parseHysteria2UDPMessage(data)
	if err != nil || header.sessionID != c.sessionID {
		return nil, false
	}
	_ = addrBytes
	if header.fragmentCount <= 1 {
		return payload, true
	}
	c.fragMu.Lock()
	defer c.fragMu.Unlock()
	if c.fragments == nil {
		c.fragments = make(map[uint16][][]byte)
		c.fragCounts = make(map[uint16]int)
	}
	if _, ok := c.fragments[header.packetID]; !ok {
		c.fragments[header.packetID] = make([][]byte, int(header.fragmentCount))
		c.fragCounts[header.packetID] = 0
	}
	if int(header.fragmentID) >= len(c.fragments[header.packetID]) {
		return nil, false
	}
	if c.fragments[header.packetID][header.fragmentID] == nil {
		c.fragments[header.packetID][header.fragmentID] = append([]byte(nil), payload...)
		c.fragCounts[header.packetID]++
	}
	if c.fragCounts[header.packetID] == int(header.fragmentCount) {
		var full []byte
		for _, part := range c.fragments[header.packetID] {
			full = append(full, part...)
		}
		delete(c.fragments, header.packetID)
		delete(c.fragCounts, header.packetID)
		return full, true
	}
	return nil, false
}

func (c *hysteria2UDPConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	packetID := uint16(c.packetID.Add(1))
	chunkSize := hysteria2MaxDatagram - 24 - len(c.target) - quicvarint.Len(uint64(len(c.target)))
	if chunkSize < 1 {
		return 0, fmt.Errorf("hysteria2: target address is too long")
	}
	if len(p) <= chunkSize {
		if err := c.sendDatagram(packetID, 0, 1, p); err != nil {
			return 0, err
		}
		return len(p), nil
	}

	count := (len(p) + chunkSize - 1) / chunkSize
	if count > 255 {
		return 0, fmt.Errorf("hysteria2: udp packet requires %d fragments, max 255", count)
	}
	for i := 0; i < count; i++ {
		start := i * chunkSize
		end := start + chunkSize
		if end > len(p) {
			end = len(p)
		}
		if err := c.sendDatagram(packetID, uint8(i), uint8(count), p[start:end]); err != nil {
			return start, err
		}
	}
	return len(p), nil
}

func (c *hysteria2UDPConn) sendDatagram(packetID uint16, fragmentID, fragmentCount uint8, payload []byte) error {
	buf := make([]byte, 0, 16+len(c.target)+len(payload))
	buf = binary.BigEndian.AppendUint32(buf, c.sessionID)
	buf = binary.BigEndian.AppendUint16(buf, packetID)
	buf = append(buf, fragmentID, fragmentCount)
	buf = quicvarint.Append(buf, uint64(len(c.target)))
	buf = append(buf, c.target...)
	buf = append(buf, payload...)
	return c.conn.SendDatagram(buf)
}

func (c *hysteria2UDPConn) Close() error {
	err := c.conn.CloseWithError(0, "udp session closed")
	if c.packetConn != nil {
		if closeErr := c.packetConn.Close(); err == nil {
			err = closeErr
		}
	}
	return err
}

func (c *hysteria2UDPConn) SetDeadline(time.Time) error      { return nil }
func (c *hysteria2UDPConn) SetReadDeadline(time.Time) error  { return nil }
func (c *hysteria2UDPConn) SetWriteDeadline(time.Time) error { return nil }

type hysteria2UDPHeader struct {
	sessionID     uint32
	packetID      uint16
	fragmentID    uint8
	fragmentCount uint8
}

func parseHysteria2UDPMessage(data []byte) (hysteria2UDPHeader, []byte, []byte, error) {
	var hdr hysteria2UDPHeader
	if len(data) < 8 {
		return hdr, nil, nil, io.ErrUnexpectedEOF
	}
	hdr.sessionID = binary.BigEndian.Uint32(data[0:4])
	hdr.packetID = binary.BigEndian.Uint16(data[4:6])
	hdr.fragmentID = data[6]
	hdr.fragmentCount = data[7]
	addrLen, consumed, err := quicvarint.Parse(data[8:])
	if err != nil {
		return hdr, nil, nil, err
	}
	addrStart := 8 + consumed
	addrEnd := addrStart + int(addrLen)
	if addrEnd > len(data) {
		return hdr, nil, nil, io.ErrUnexpectedEOF
	}
	return hdr, data[addrStart:addrEnd], data[addrEnd:], nil
}

func randomUint32() uint32 {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		return uint32(time.Now().UnixNano())
	}
	return binary.BigEndian.Uint32(b[:])
}

func randomPadding(min, max int) string {
	n := min
	if max > min {
		var b [2]byte
		if _, err := rand.Read(b[:]); err == nil {
			n = min + int(binary.BigEndian.Uint16(b[:]))%(max-min+1)
		}
	}
	buf := make([]byte, n)
	_, _ = rand.Read(buf)
	for i := range buf {
		buf[i] = 'a' + buf[i]%26
	}
	return string(buf)
}

var _ model.Outbound = (*Hysteria2)(nil)
