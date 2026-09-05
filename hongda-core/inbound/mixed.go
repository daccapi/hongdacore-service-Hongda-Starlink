package inbound

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"

	"hongda.local/hongda-core/route"
)

// Mixed serves SOCKS5 (no auth) and HTTP CONNECT on a single TCP listener.
type Mixed struct {
	router      *route.Router
	ln          net.Listener
	udpLn       *net.UDPConn
	udpMu       sync.Mutex
	udpSessions map[string]*udpRelaySession
}

type udpRelaySession struct {
	client *net.UDPAddr
	target string
	conn   net.Conn
	once   sync.Once
}

func NewMixed(router *route.Router) *Mixed {
	return &Mixed{router: router, udpSessions: make(map[string]*udpRelaySession)}
}

func (m *Mixed) Start(addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("listen mixed %s: %w", addr, err)
	}
	m.ln = ln
	udpLn, err := net.ListenUDP("udp", &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 0})
	if err != nil {
		_ = ln.Close()
		return fmt.Errorf("listen udp associate: %w", err)
	}
	m.udpLn = udpLn
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
	if m.udpLn != nil {
		_ = m.udpLn.Close()
	}
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
	host, port, ok := readSOCKS5Address(br)
	if !ok {
		_ = socksReply(client, 0x08)
		return
	}
	if req[1] == 0x03 {
		m.handleUDPAssociate(client, host, port)
		return
	}
	if req[1] != 0x01 {
		_ = socksReply(client, 0x07)
		return
	}

	upstream, err := m.router.Dial("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		_ = socksReply(client, 0x05)
		return
	}
	defer upstream.Close()
	_ = socksReply(client, 0x00)
	m.router.Pipe(client, upstream)
}

func readSOCKS5Address(br *bufio.Reader) (string, int, bool) {
	var atyp [1]byte
	if _, err := io.ReadFull(br, atyp[:]); err != nil {
		return "", 0, false
	}
	var host string
	switch atyp[0] {
	case 0x01:
		ip := make([]byte, 4)
		if _, err := io.ReadFull(br, ip); err != nil {
			return "", 0, false
		}
		host = net.IP(ip).String()
	case 0x03:
		b := make([]byte, 1)
		if _, err := io.ReadFull(br, b); err != nil {
			return "", 0, false
		}
		name := make([]byte, int(b[0]))
		if _, err := io.ReadFull(br, name); err != nil {
			return "", 0, false
		}
		host = string(name)
	case 0x04:
		ip := make([]byte, 16)
		if _, err := io.ReadFull(br, ip); err != nil {
			return "", 0, false
		}
		host = net.IP(ip).String()
	default:
		return "", 0, false
	}
	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(br, portBuf); err != nil {
		return "", 0, false
	}
	port := int(binary.BigEndian.Uint16(portBuf))
	return host, port, true
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

func (m *Mixed) handleUDPAssociate(client net.Conn, _ string, _ int) {
	addr := m.udpLn.LocalAddr().(*net.UDPAddr)
	reply := []byte{0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, byte(addr.Port >> 8), byte(addr.Port)}
	if _, err := client.Write(reply); err != nil {
		return
	}

	go func() {
		buf := make([]byte, 1)
		for {
			if _, err := client.Read(buf); err != nil {
				_ = m.udpLn.Close()
				return
			}
		}
	}()

	buf := make([]byte, 64*1024)
	for {
		n, clientAddr, err := m.udpLn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		target, payload, ok := parseSOCKS5UDPHeader(buf[:n])
		if !ok {
			continue
		}
		key := clientAddr.String() + "|" + target
		m.udpMu.Lock()
		session := m.udpSessions[key]
		if session == nil {
			upstream, err := m.router.Dial("udp", target)
			if err != nil {
				m.udpMu.Unlock()
				continue
			}
			session = &udpRelaySession{client: clientAddr, target: target, conn: upstream}
			m.udpSessions[key] = session
			go m.relayUDPFromUpstream(session)
		}
		m.udpMu.Unlock()
		if _, err := session.conn.Write(payload); err != nil {
			m.removeUDPSession(key, session)
		}
	}
}

func (m *Mixed) relayUDPFromUpstream(session *udpRelaySession) {
	buf := make([]byte, 64*1024)
	for {
		n, err := session.conn.Read(buf)
		if err != nil {
			m.removeUDPSession(session.client.String()+"|"+session.target, session)
			return
		}
		header, ok := socks5UDPHeader(session.target)
		if !ok {
			continue
		}
		packet := append(append([]byte(nil), header...), buf[:n]...)
		_, _ = m.udpLn.WriteToUDP(packet, session.client)
	}
}

func (m *Mixed) removeUDPSession(key string, session *udpRelaySession) {
	m.udpMu.Lock()
	if m.udpSessions[key] == session {
		delete(m.udpSessions, key)
	}
	m.udpMu.Unlock()
	session.once.Do(func() { _ = session.conn.Close() })
}

func parseSOCKS5UDPHeader(data []byte) (string, []byte, bool) {
	if len(data) < 4 || data[0] != 0 || data[1] != 0 || data[2] != 0 {
		return "", nil, false
	}
	var host string
	switch data[3] {
	case 0x01:
		if len(data) < 4+4+2 {
			return "", nil, false
		}
		host = net.IP(data[4:8]).String()
		data = data[8:]
	case 0x04:
		if len(data) < 4+16+2 {
			return "", nil, false
		}
		host = net.IP(data[4:20]).String()
		data = data[20:]
	case 0x03:
		if len(data) < 5 {
			return "", nil, false
		}
		nameLen := int(data[4])
		if len(data) < 5+nameLen+2 {
			return "", nil, false
		}
		host = string(data[5 : 5+nameLen])
		data = data[5+nameLen:]
	default:
		return "", nil, false
	}
	if len(data) < 2 {
		return "", nil, false
	}
	port := int(binary.BigEndian.Uint16(data[:2]))
	payload := data[2:]
	return net.JoinHostPort(host, strconv.Itoa(port)), payload, true
}

func socks5UDPHeader(target string) ([]byte, bool) {
	host, portStr, err := net.SplitHostPort(target)
	if err != nil {
		return nil, false
	}
	port, err := strconv.Atoi(portStr)
	if err != nil || port < 0 || port > 65535 {
		return nil, false
	}
	header := []byte{0, 0, 0}
	if ip := net.ParseIP(host); ip != nil {
		if v4 := ip.To4(); v4 != nil {
			header = append(header, 0x01)
			header = append(header, v4...)
		} else {
			header = append(header, 0x04)
			header = append(header, ip.To16()...)
		}
	} else {
		header = append(header, 0x03, byte(len(host)))
		header = append(header, host...)
	}
	header = append(header, byte(port>>8), byte(port))
	return header, true
}

func socksReply(conn net.Conn, code byte) error {
	_, err := conn.Write([]byte{0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	return err
}
