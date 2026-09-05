package protocol

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"

	"hongda.local/hongda-core/model"
)

// VLESS implements the VLESS TCP outbound. Reality and vision flow are added
// in a later phase; basic TLS and raw TCP are supported now.
type VLESS struct {
	id        string
	server    string
	port      uint16
	uuid      []byte
	flow      string
	tls       *model.TLSOptions
	transport *model.TransportOptions
}

func NewVLESS(node model.Node) (*VLESS, error) {
	uuidStr := node.Auth["uuid"]
	uuidBytes, err := parseUUID(uuidStr)
	if err != nil {
		return nil, err
	}
	return &VLESS{
		id:        node.ID,
		server:    node.Server,
		port:      node.Port,
		uuid:      uuidBytes,
		flow:      node.Auth["flow"],
		tls:       node.TLS,
		transport: node.Transport,
	}, nil
}

func (v *VLESS) ID() string               { return v.id }
func (v *VLESS) Type() model.ProtocolType { return model.ProtocolVLESS }
func (v *VLESS) SupportUDP() bool         { return true }
func (v *VLESS) Close() error             { return nil }

func (v *VLESS) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	command := byte(0x01)
	switch network {
	case "tcp":
	case "udp":
		command = 0x02
	default:
		return nil, fmt.Errorf("vless supports tcp and udp only")
	}
	host, port, err := splitAddress(address)
	if err != nil {
		return nil, err
	}
	conn, err := v.dialTransport(ctx)
	if err != nil {
		return nil, err
	}

	header := make([]byte, 0, 64)
	header = append(header, 0x00)
	header = append(header, v.uuid...)
	if v.flow == "" {
		header = append(header, 0x00)
	} else {
		addons := []byte("M" + v.flow)
		header = append(header, byte(len(addons)))
		header = append(header, addons...)
	}
	header = append(header, command)
	header = append(header, vlessAddress(host, port)...)

	if _, err := conn.Write(header); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := readVLESSResponse(conn); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if network == "udp" {
		return &vlessUDPConn{Conn: conn}, nil
	}
	return conn, nil
}

func (v *VLESS) DialUDP(ctx context.Context, address string) (net.Conn, error) {
	return v.DialContext(ctx, "udp", address)
}

func (v *VLESS) dialTransport(ctx context.Context) (net.Conn, error) {
	return dialTransportConn(ctx, v.server, v.port, v.tls, v.transport)
}

func (v *VLESS) ListenPacket(ctx context.Context, address string) (net.PacketConn, error) {
	conn, err := v.DialUDP(ctx, address)
	if err != nil {
		return nil, err
	}
	pc := &udpConnPacketConn{Conn: conn}
	return pc, nil
}

var _ model.Outbound = (*VLESS)(nil)

type vlessUDPConn struct {
	net.Conn
	readMu  sync.Mutex
	writeMu sync.Mutex
	buf     []byte
}

func (c *vlessUDPConn) Read(p []byte) (int, error) {
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

func (c *vlessUDPConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	var lenBuf [2]byte
	binary.BigEndian.PutUint16(lenBuf[:], uint16(len(p)))
	if _, err := c.Conn.Write(lenBuf[:]); err != nil {
		return 0, err
	}
	if _, err := c.Conn.Write(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

type udpConnPacketConn struct {
	net.Conn
}

func (c *udpConnPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	n, err := c.Conn.Read(p)
	return n, c.Conn.RemoteAddr(), err
}

func (c *udpConnPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	return c.Conn.Write(p)
}

func readVLESSResponse(conn net.Conn) error {
	var resp [2]byte
	if _, err := io.ReadFull(conn, resp[:]); err != nil {
		return fmt.Errorf("vless: read response: %w", err)
	}
	if resp[0] != 0x00 {
		return fmt.Errorf("vless: invalid response version %d", resp[0])
	}
	return nil
}
