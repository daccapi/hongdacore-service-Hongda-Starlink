package protocol

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"log"
	"net"
	"os"
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
	writeBuf   []byte
	readDirect net.Conn
	writeTLS   bool
	writeCount int
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
			if c.readDirect != nil {
				return c.readDirect.Read(p)
			}
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
			c.trace("read", cmd, int(contentLen), int(paddingLen))
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
		c.trace("read", cmd, int(contentLen), int(paddingLen))
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
	if cmd == visionCommandDirect {
		c.readDirect = unwrapTLSConn(c.Conn)
	}
	if cmd != visionCommandContinue {
		c.readRaw = true
	}
	return nil
}

func unwrapTLSConn(conn net.Conn) net.Conn {
	for {
		if wrapper, ok := conn.(*vlessResponseConn); ok {
			conn = wrapper.Conn
			continue
		}
		if tlsConn, ok := conn.(interface{ NetConn() net.Conn }); ok {
			return tlsConn.NetConn()
		}
		return conn
	}
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

	accepted := len(p)
	c.writeBuf = append(c.writeBuf, p...)
	for len(c.writeBuf) > 0 {
		size := len(c.writeBuf)
		if looksLikeTLSRecord(c.writeBuf) {
			if len(c.writeBuf) < 5 {
				return accepted, nil
			}
			size = 5 + int(binary.BigEndian.Uint16(c.writeBuf[3:5]))
			if len(c.writeBuf) < size {
				return accepted, nil
			}
		} else if len(c.writeBuf) < 5 && !c.writeTLS {
			// A TCP proxy may split the five-byte TLS record header. Accept the
			// bytes now and flush them as soon as the remainder arrives.
			return accepted, nil
		}
		if size > visionMaxContentSize {
			size = visionMaxContentSize
		}
		chunk := c.writeBuf[:size]
		cmd := visionCommandContinue
		if c.shouldEndPadding(chunk) {
			cmd = visionCommandEnd
		}
		if err := c.writeVisionFrame(cmd, chunk); err != nil {
			return 0, err
		}
		c.writeBuf = c.writeBuf[size:]
		if cmd != visionCommandContinue {
			c.writeRaw = true
			if len(c.writeBuf) > 0 {
				if _, err := c.Conn.Write(c.writeBuf); err != nil {
					return 0, err
				}
				c.writeBuf = nil
			}
		}
	}
	return accepted, nil
}

func (c *vlessVisionConn) shouldEndPadding(content []byte) bool {
	c.writeCount++
	if bytes.Contains(content, []byte{0x16, 0x03}) {
		c.writeTLS = true
	}
	for offset := 0; offset+5 <= len(content); offset++ {
		if content[offset] != 0x17 || content[offset+1] != 0x03 || content[offset+2] != 0x03 {
			continue
		}
		recordLen := int(binary.BigEndian.Uint16(content[offset+3 : offset+5]))
		if len(content)-offset-5 >= recordLen {
			return true
		}
	}
	// Non-TLS streams must eventually leave padding mode as well. For a
	// recognized TLS stream, never use the write-call count as a boundary: TCP
	// can split a ClientHello into an arbitrary number of reads.
	return !c.writeTLS && c.writeCount >= 8
}

func looksLikeTLSRecord(content []byte) bool {
	if len(content) < 3 {
		return true
	}
	return content[0] >= 0x14 && content[0] <= 0x17 && content[1] == 0x03
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
	c.trace("write", cmd, len(content), 0)
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

func (c *vlessVisionConn) trace(direction string, command byte, contentLen, paddingLen int) {
	if os.Getenv("HONGDA_TRACE_VISION") == "1" {
		log.Printf("vision conn=%p %s command=%d content=%d padding=%d raw(write=%t read=%t)", c, direction, command, contentLen, paddingLen, c.writeRaw, c.readRaw)
	}
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
