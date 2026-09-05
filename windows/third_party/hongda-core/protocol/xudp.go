package protocol

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
)

// XUDP is Xray's Mux.Cool based UDP transport used by VLESS outbounds. It
// reuses the wire format described by the public Mux.Cool and XUDP protocol
// documents; no sing-box or Xray source code is imported or copied.
//
// A VLESS XUDP connection is established to the magic address v1.mux.cool:666
// with command Mux (0x03). Each datagram is then carried in a mux frame:
//
//   - first datagram: New frame with destination and an 8-byte GlobalID
//   - following datagrams: Keep frames with the per-packet destination
//   - close: End frame
//
// Session ID is always 0, which is how the server distinguishes XUDP from
// regular mux traffic.
const (
	muxStatusNew       byte = 0x01
	muxStatusKeep      byte = 0x02
	muxStatusEnd       byte = 0x03
	muxStatusKeepAlive byte = 0x04

	muxOptionData  byte = 0x01
	muxOptionError byte = 0x02

	muxNetworkTCP byte = 0x01
	muxNetworkUDP byte = 0x02

	xudpSessionID uint16 = 0
	xudpMagicHost        = "v1.mux.cool"
	xudpMagicPort        = 666
)

// muxAddressBytes encodes the address in Mux.Cool order: address type (1)
// followed by the address. Port and network are handled by the caller.
func muxAddressBytes(host string) []byte {
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			return append([]byte{0x01}, v4...)
		}
		return append([]byte{0x03}, ip.To16()...)
	}
	out := make([]byte, 0, len(host)+2)
	out = append(out, 0x02, byte(len(host)))
	out = append(out, host...)
	return out
}

// parseMuxAddress decodes a Mux.Cool address and returns the host plus how
// many bytes were consumed.
func parseMuxAddress(data []byte) (host string, consumed int, err error) {
	if len(data) < 1 {
		return "", 0, io.ErrUnexpectedEOF
	}
	switch data[0] {
	case 0x01:
		if len(data) < 5 {
			return "", 0, io.ErrUnexpectedEOF
		}
		return net.IP(data[1:5]).String(), 5, nil
	case 0x03:
		if len(data) < 17 {
			return "", 0, io.ErrUnexpectedEOF
		}
		return net.IP(data[1:17]).String(), 17, nil
	case 0x02:
		if len(data) < 2 {
			return "", 0, io.ErrUnexpectedEOF
		}
		n := int(data[1])
		if len(data) < 2+n {
			return "", 0, io.ErrUnexpectedEOF
		}
		return string(data[2 : 2+n]), 2 + n, nil
	default:
		return "", 0, fmt.Errorf("mux: unknown address type %d", data[0])
	}
}

// buildMuxFrame serializes a mux metadata block plus an optional length
// prefixed data payload. The Option Data bit is implied by a non-nil payload.
func buildMuxFrame(meta, payload []byte) []byte {
	out := binary.BigEndian.AppendUint16(nil, uint16(len(meta)))
	out = append(out, meta...)
	if payload != nil {
		out = binary.BigEndian.AppendUint16(out, uint16(len(payload)))
		out = append(out, payload...)
	}
	return out
}

func buildXUDPNew(host string, port uint16, globalID, payload []byte) []byte {
	meta := make([]byte, 0, 32)
	meta = binary.BigEndian.AppendUint16(meta, xudpSessionID)
	meta = append(meta, muxStatusNew, muxOptionData, muxNetworkUDP)
	meta = binary.BigEndian.AppendUint16(meta, port)
	meta = append(meta, muxAddressBytes(host)...)
	meta = append(meta, globalID...)
	return buildMuxFrame(meta, payload)
}

func buildXUDPKeep(host string, port uint16, payload []byte) []byte {
	meta := make([]byte, 0, 24)
	meta = binary.BigEndian.AppendUint16(meta, xudpSessionID)
	meta = append(meta, muxStatusKeep, muxOptionData, muxNetworkUDP)
	meta = binary.BigEndian.AppendUint16(meta, port)
	meta = append(meta, muxAddressBytes(host)...)
	return buildMuxFrame(meta, payload)
}

func buildXUDPEnd() []byte {
	meta := make([]byte, 0, 4)
	meta = binary.BigEndian.AppendUint16(meta, xudpSessionID)
	meta = append(meta, muxStatusEnd, 0x00)
	return buildMuxFrame(meta, nil)
}

// xudpFrame is the decoded result of one mux frame. Not every field is needed
// by the data path, but keeping host/port/globalID makes the codec easy to
// test and future-proof for shared-connection demultiplexing.
type xudpFrame struct {
	status   byte
	option   byte
	host     string
	port     uint16
	globalID []byte
	data     []byte
}

// decodeXUDPFrame reads one mux frame from r and decodes its metadata and
// optional payload. It skips the address block inside Keep/New metadata so the
// caller only has to deal with the datagram bytes.
func decodeXUDPFrame(r io.Reader) (xudpFrame, error) {
	var f xudpFrame
	var lenBuf [2]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return f, err
	}
	metaLen := int(binary.BigEndian.Uint16(lenBuf[:]))
	meta := make([]byte, metaLen)
	if _, err := io.ReadFull(r, meta); err != nil {
		return f, err
	}
	if metaLen < 4 {
		return f, fmt.Errorf("xudp: short metadata %d", metaLen)
	}
	f.status = meta[2]
	f.option = meta[3]
	rest := meta[4:]
	if len(rest) > 0 {
		host, port, globalID, err := parseXUDPTarget(rest, f.status)
		if err != nil {
			return f, err
		}
		f.host, f.port, f.globalID = host, port, globalID
	}
	if f.option&muxOptionData != 0 {
		var dlen [2]byte
		if _, err := io.ReadFull(r, dlen[:]); err != nil {
			return f, err
		}
		n := int(binary.BigEndian.Uint16(dlen[:]))
		f.data = make([]byte, n)
		if _, err := io.ReadFull(r, f.data); err != nil {
			return f, err
		}
	}
	return f, nil
}

// parseXUDPTarget decodes the address block that follows the status/option
// bytes in a New or Keep frame. New frames additionally carry an 8-byte
// GlobalID after the address.
func parseXUDPTarget(rest []byte, status byte) (host string, port uint16, globalID []byte, err error) {
	if len(rest) < 4 {
		return "", 0, nil, io.ErrUnexpectedEOF
	}
	port = binary.BigEndian.Uint16(rest[1:3])
	host, consumed, err := parseMuxAddress(rest[3:])
	if err != nil {
		return "", 0, nil, err
	}
	consumed += 3
	if status == muxStatusNew {
		if len(rest) < consumed+8 {
			return "", 0, nil, io.ErrUnexpectedEOF
		}
		globalID = append([]byte(nil), rest[consumed:consumed+8]...)
	}
	return host, port, globalID, nil
}

// xudpConn is a net.Conn view over one VLESS XUDP session. It sends New/Keep
// frames for writes and decodes Keep frames for reads. It is intended for a
// single destination session, which is how the mixed inbound currently opens
// one upstream connection per UDP target.
type xudpConn struct {
	net.Conn
	host     string
	port     uint16
	globalID []byte
	first    bool

	readMu  sync.Mutex
	writeMu sync.Mutex
	buf     []byte
}

func newXUDPConn(conn net.Conn, host string, port uint16) (*xudpConn, error) {
	globalID := make([]byte, 8)
	if _, err := rand.Read(globalID); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &xudpConn{
		Conn:     conn,
		host:     host,
		port:     port,
		globalID: globalID,
		first:    true,
	}, nil
}

func (c *xudpConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	for {
		if len(p) == 0 {
			return 0, nil
		}
		if len(c.buf) > 0 {
			n := copy(p, c.buf)
			c.buf = c.buf[n:]
			return n, nil
		}
		frame, err := decodeXUDPFrame(c.Conn)
		if err != nil {
			return 0, err
		}
		switch frame.status {
		case muxStatusEnd:
			return 0, io.EOF
		case muxStatusKeepAlive:
			continue
		}
		if len(frame.data) == 0 {
			continue
		}
		n := copy(p, frame.data)
		c.buf = frame.data[n:]
		return n, nil
	}
}

func (c *xudpConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	var frame []byte
	if c.first {
		frame = buildXUDPNew(c.host, c.port, c.globalID, p)
		c.first = false
	} else {
		frame = buildXUDPKeep(c.host, c.port, p)
	}
	if _, err := c.Conn.Write(frame); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (c *xudpConn) Close() error {
	c.writeMu.Lock()
	_, _ = c.Conn.Write(buildXUDPEnd())
	c.writeMu.Unlock()
	return c.Conn.Close()
}
