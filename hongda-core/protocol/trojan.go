package protocol

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"sync"

	"hongda.local/hongda-core/model"
)

// Trojan implements the Trojan TCP outbound with basic TLS.
type Trojan struct {
	id        string
	server    string
	port      uint16
	password  string
	tls       *model.TLSOptions
	transport *model.TransportOptions
}

func NewTrojan(node model.Node) (*Trojan, error) {
	password := node.Auth["password"]
	if password == "" {
		return nil, fmt.Errorf("trojan password is required")
	}
	return &Trojan{
		id:        node.ID,
		server:    node.Server,
		port:      node.Port,
		password:  password,
		tls:       node.TLS,
		transport: node.Transport,
	}, nil
}

func (t *Trojan) ID() string               { return t.id }
func (t *Trojan) Type() model.ProtocolType { return model.ProtocolTrojan }
func (t *Trojan) SupportUDP() bool         { return true }
func (t *Trojan) Close() error             { return nil }

func (t *Trojan) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	command := byte(0x01)
	switch network {
	case "tcp":
	case "udp":
		command = 0x03
	default:
		return nil, fmt.Errorf("trojan supports tcp and udp only")
	}
	host, port, err := splitAddress(address)
	if err != nil {
		return nil, err
	}
	conn, err := dialTransportConn(ctx, t.server, t.port, t.tls, t.transport)
	if err != nil {
		return nil, err
	}

	sum := sha256.Sum224([]byte(t.password))
	header := make([]byte, 0, 96)
	header = append(header, hex.EncodeToString(sum[:])...)
	header = append(header, '\r', '\n')
	targetHeader := trojanAddress(host, port)
	header = append(header, command)
	header = append(header, targetHeader...)
	header = append(header, '\r', '\n')

	if _, err := conn.Write(header); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if network == "udp" {
		return &trojanUDPConn{Conn: conn, target: targetHeader}, nil
	}
	return conn, nil
}

func (t *Trojan) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	conn, err := t.DialContext(ctx, "udp", address)
	if err != nil {
		return nil, err
	}
	return &udpConnPacketConn{Conn: conn}, nil
}

var _ model.Outbound = (*Trojan)(nil)

type trojanUDPConn struct {
	net.Conn
	target  []byte
	readMu  sync.Mutex
	writeMu sync.Mutex
	buf     []byte
}

func (c *trojanUDPConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	if len(p) == 0 {
		return 0, nil
	}
	if len(c.buf) > 0 {
		n := copy(p, c.buf)
		c.buf = c.buf[n:]
		return n, nil
	}
	if _, err := readTrojanAddress(c.Conn); err != nil {
		return 0, err
	}
	var lenBuf [2]byte
	if _, err := io.ReadFull(c.Conn, lenBuf[:]); err != nil {
		return 0, err
	}
	length := int(binary.BigEndian.Uint16(lenBuf[:]))
	if length <= 0 {
		return 0, io.ErrUnexpectedEOF
	}
	packet := make([]byte, length)
	if _, err := io.ReadFull(c.Conn, packet); err != nil {
		return 0, err
	}
	n := copy(p, packet)
	c.buf = packet[n:]
	return n, nil
}

func (c *trojanUDPConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	var lenBuf [2]byte
	binary.BigEndian.PutUint16(lenBuf[:], uint16(len(p)))
	if _, err := c.Conn.Write(c.target); err != nil {
		return 0, err
	}
	if _, err := c.Conn.Write(lenBuf[:]); err != nil {
		return 0, err
	}
	if _, err := c.Conn.Write(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func readTrojanAddress(r io.Reader) ([]byte, error) {
	var atyp [1]byte
	if _, err := io.ReadFull(r, atyp[:]); err != nil {
		return nil, err
	}
	header := []byte{atyp[0]}
	var addrLen int
	switch atyp[0] {
	case 0x01:
		addrLen = 4
	case 0x04:
		addrLen = 16
	case 0x03:
		var b [1]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return nil, err
		}
		header = append(header, b[0])
		addrLen = int(b[0])
	default:
		return nil, fmt.Errorf("trojan: unknown address type %d", atyp[0])
	}
	if addrLen > 0 {
		addr := make([]byte, addrLen)
		if _, err := io.ReadFull(r, addr); err != nil {
			return nil, err
		}
		header = append(header, addr...)
	}
	var port [2]byte
	if _, err := io.ReadFull(r, port[:]); err != nil {
		return nil, err
	}
	header = append(header, port[:]...)
	return header, nil
}
