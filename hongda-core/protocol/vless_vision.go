package protocol

import (
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
)

const (
	visionCommandContinue byte = 0x00
	visionCommandEnd      byte = 0x01
	visionCommandDirect   byte = 0x02

	visionFirstHeaderLen = 16 + 1 + 2 + 2
	visionSubHeaderLen   = 1 + 2 + 2
	visionMaxContentSize = 0xFFFF
)

// vlessVisionConn wraps a VLESS TCP connection after the VLESS handshake and
// applies the XTLS Vision padding frames. It intentionally does not implement
// TLS splicing: traffic still goes through the outer TLS connection, but the
// padding framing remains wire-compatible for servers that use Vision.
type vlessVisionConn struct {
	net.Conn
	uuid []byte

	writeMu    sync.Mutex
	readMu     sync.Mutex
	firstWrite bool
	firstRead  bool
	writeRaw   bool
	readRaw    bool
	readBuf    []byte
}

func newVlessVisionConn(conn net.Conn, uuid []byte) *vlessVisionConn {
	return &vlessVisionConn{
		Conn:       conn,
		uuid:       append([]byte(nil), uuid...),
		firstWrite: true,
		firstRead:  true,
	}
}

func (c *vlessVisionConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()

	for {
		if len(p) == 0 {
			return 0, nil
		}
		if len(c.readBuf) > 0 {
			n := copy(p, c.readBuf)
			c.readBuf = c.readBuf[n:]
			return n, nil
		}
		if c.readRaw {
			return c.Conn.Read(p)
		}

		if c.firstRead {
			header := make([]byte, visionFirstHeaderLen)
			if _, err := io.ReadFull(c.Conn, header); err != nil {
				return 0, err
			}
			c.firstRead = false
			if !equalBytes(header[:16], c.uuid) {
				// Some servers may omit the initial UUID frame and switch to
				// raw traffic immediately. Preserve the bytes we already read.
				c.readRaw = true
				c.readBuf = append(c.readBuf, header...)
				continue
			}
			cmd, contentLen, paddingLen := header[16], binary.BigEndian.Uint16(header[17:19]), binary.BigEndian.Uint16(header[19:21])
			if err := c.readVisionContent(cmd, contentLen, paddingLen); err != nil {
				return 0, err
			}
			continue
		}

		header := make([]byte, visionSubHeaderLen)
		if _, err := io.ReadFull(c.Conn, header); err != nil {
			return 0, err
		}
		cmd := header[0]
		contentLen := binary.BigEndian.Uint16(header[1:3])
		paddingLen := binary.BigEndian.Uint16(header[3:5])
		if err := c.readVisionContent(cmd, contentLen, paddingLen); err != nil {
			return 0, err
		}
	}
}

func (c *vlessVisionConn) readVisionContent(cmd byte, contentLen, paddingLen uint16) error {
	if contentLen > 0 {
		content := make([]byte, int(contentLen))
		if _, err := io.ReadFull(c.Conn, content); err != nil {
			return err
		}
		c.readBuf = append(c.readBuf, content...)
	}
	if paddingLen > 0 {
		if _, err := io.CopyN(io.Discard, c.Conn, int64(paddingLen)); err != nil {
			return err
		}
	}
	if cmd != visionCommandContinue {
		c.readRaw = true
	}
	return nil
}

func (c *vlessVisionConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	if len(p) == 0 {
		return 0, nil
	}
	if c.writeRaw {
		return c.Conn.Write(p)
	}

	total := 0
	for len(p) > 0 {
		size := len(p)
		if size > visionMaxContentSize {
			size = visionMaxContentSize
		}
		chunk := p[:size]
		p = p[size:]

		cmd := visionCommandContinue
		if len(p) == 0 {
			cmd = visionCommandEnd
		}
		if err := c.writeVisionFrame(cmd, chunk); err != nil {
			return total, err
		}
		total += size
		if cmd != visionCommandContinue {
			c.writeRaw = true
		}
	}
	return total, nil
}

func (c *vlessVisionConn) writeVisionFrame(cmd byte, content []byte) error {
	if len(content) > visionMaxContentSize {
		return fmt.Errorf("vless vision: content length %d exceeds %d", len(content), visionMaxContentSize)
	}
	header := make([]byte, 0, visionFirstHeaderLen)
	if c.firstWrite {
		header = append(header, c.uuid...)
		c.firstWrite = false
	}
	header = append(header, cmd)
	header = binary.BigEndian.AppendUint16(header, uint16(len(content)))
	header = binary.BigEndian.AppendUint16(header, 0)
	if _, err := c.Conn.Write(header); err != nil {
		return err
	}
	if len(content) > 0 {
		if _, err := c.Conn.Write(content); err != nil {
			return err
		}
	}
	return nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
