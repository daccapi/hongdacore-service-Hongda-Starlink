package inbound

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"

	"hongda.local/hongda-core/route"
)

// Mixed serves SOCKS5 (no auth) and HTTP CONNECT on a single TCP listener.
type Mixed struct {
	router *route.Router
	ln     net.Listener
}

func NewMixed(router *route.Router) *Mixed {
	return &Mixed{router: router}
}

func (m *Mixed) Start(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen mixed %s: %w", addr, err)
	}
	m.ln = ln
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go m.handle(conn)
		}
	}()
	return nil
}

func (m *Mixed) Close() error {
	if m.ln != nil {
		return m.ln.Close()
	}
	return nil
}

func (m *Mixed) handle(client net.Conn) {
	defer client.Close()
	br := bufio.NewReader(client)
	first, err := br.Peek(1)
	if err != nil {
		return
	}
	if first[0] == 0x05 {
		m.handleSOCKS5(client, br)
		return
	}
	m.handleHTTPConnect(client, br)
}

func (m *Mixed) handleSOCKS5(client net.Conn, br *bufio.Reader) {
	var hdr [2]byte
	if _, err := io.ReadFull(br, hdr[:]); err != nil {
		return
	}
	if hdr[0] != 0x05 {
		return
	}
	methods := make([]byte, int(hdr[1]))
	if _, err := io.ReadFull(br, methods); err != nil {
		return
	}
	if _, err := client.Write([]byte{0x05, 0x00}); err != nil {
		return
	}

	var req [4]byte
	if _, err := io.ReadFull(br, req[:]); err != nil {
		return
	}
	if req[1] != 0x01 {
		_ = socksReply(client, 0x07)
		return
	}
	var host string
	switch req[3] {
	case 0x01:
		ip := make([]byte, 4)
		if _, err := io.ReadFull(br, ip); err != nil {
			return
		}
		host = net.IP(ip).String()
	case 0x03:
		b := make([]byte, 1)
		if _, err := io.ReadFull(br, b); err != nil {
			return
		}
		name := make([]byte, int(b[0]))
		if _, err := io.ReadFull(br, name); err != nil {
			return
		}
		host = string(name)
	case 0x04:
		ip := make([]byte, 16)
		if _, err := io.ReadFull(br, ip); err != nil {
			return
		}
		host = net.IP(ip).String()
	default:
		_ = socksReply(client, 0x08)
		return
	}
	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(br, portBuf); err != nil {
		return
	}
	port := int(binary.BigEndian.Uint16(portBuf))

	upstream, err := m.router.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		_ = socksReply(client, 0x05)
		return
	}
	defer upstream.Close()
	_ = socksReply(client, 0x00)
	m.router.Pipe(client, upstream)
}

func (m *Mixed) handleHTTPConnect(client net.Conn, br *bufio.Reader) {
	line, err := br.ReadString('\n')
	if err != nil {
		return
	}
	parts := strings.Fields(line)
	if len(parts) != 3 || parts[0] != "CONNECT" {
		return
	}
	host, portStr, err := net.SplitHostPort(parts[1])
	if err != nil {
		_, _ = io.WriteString(client, "HTTP/1.1 400 Bad Request\r\n\r\n")
		return
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		_, _ = io.WriteString(client, "HTTP/1.1 400 Bad Request\r\n\r\n")
		return
	}
	for {
		header, readErr := br.ReadString('\n')
		if readErr != nil {
			return
		}
		if header == "\r\n" || header == "\n" {
			break
		}
	}
	upstream, err := m.router.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		_, _ = io.WriteString(client, "HTTP/1.1 502 Bad Gateway\r\n\r\n")
		return
	}
	defer upstream.Close()
	if _, err := io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	m.router.Pipe(client, upstream)
}

func socksReply(conn net.Conn, code byte) error {
	_, err := conn.Write([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	return err
}
