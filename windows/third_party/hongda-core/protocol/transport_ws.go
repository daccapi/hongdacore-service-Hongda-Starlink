package protocol

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"hongda.local/hongda-core/model"
)

const websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	wsContinuation = 0x0
	wsText         = 0x1
	wsBinary       = 0x2
	wsClose        = 0x8
	wsPing         = 0x9
	wsPong         = 0xA
)

type websocketConn struct {
	net.Conn
	br       *bufio.Reader
	writeMu  sync.Mutex
	readMu   sync.Mutex
	pending  []byte
	closeErr error
}

func websocketDial(ctx context.Context, base net.Conn, host string, port uint16, transport *model.TransportOptions) (net.Conn, error) {
	_ = ctx
	path := transport.Path
	if path == "" {
		path = "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	hostHeader := transport.Host
	if hostHeader == "" {
		hostHeader = host
	}

	var keyBytes [16]byte
	if _, err := io.ReadFull(rand.Reader, keyBytes[:]); err != nil {
		_ = base.Close()
		return nil, fmt.Errorf("websocket: generate key: %w", err)
	}
	key := base64.StdEncoding.EncodeToString(keyBytes[:])

	req := &http.Request{
		Method: "GET",
		URL:    &url.URL{Path: path},
		Host:   hostHeader,
		Header: http.Header{},
	}
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Sec-WebSocket-Key", key)
	req.Header.Set("Sec-WebSocket-Version", "13")
	if err := req.Write(base); err != nil {
		_ = base.Close()
		return nil, fmt.Errorf("websocket: write request: %w", err)
	}

	br := bufio.NewReader(base)
	resp, err := http.ReadResponse(br, req)
	if err != nil {
		_ = base.Close()
		return nil, fmt.Errorf("websocket: read response: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusSwitchingProtocols {
		_ = base.Close()
		return nil, fmt.Errorf("websocket: unexpected status %d", resp.StatusCode)
	}
	if !headerContainsToken(resp.Header, "Upgrade", "websocket") ||
		!headerContainsToken(resp.Header, "Connection", "Upgrade") {
		_ = base.Close()
		return nil, fmt.Errorf("websocket: invalid upgrade headers")
	}
	expected := websocketAccept(key)
	if !strings.EqualFold(resp.Header.Get("Sec-WebSocket-Accept"), expected) {
		_ = base.Close()
		return nil, fmt.Errorf("websocket: invalid sec-websocket-accept")
	}
	return &websocketConn{Conn: base, br: br}, nil
}

func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + websocketGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

func headerContainsToken(h http.Header, name, token string) bool {
	for _, part := range strings.Split(h.Get(name), ",") {
		if strings.EqualFold(strings.TrimSpace(part), token) {
			return true
		}
	}
	return false
}

func (w *websocketConn) Read(p []byte) (int, error) {
	w.readMu.Lock()
	defer w.readMu.Unlock()

	if len(p) == 0 {
		return 0, nil
	}
	if w.closeErr != nil {
		return 0, w.closeErr
	}
	if len(w.pending) > 0 {
		n := copy(p, w.pending)
		w.pending = w.pending[n:]
		return n, nil
	}

	for {
		opcode, payload, err := w.readFrame()
		if err != nil {
			w.closeErr = err
			return 0, err
		}
		switch opcode {
		case wsText, wsBinary:
			if len(payload) == 0 {
				continue
			}
			n := copy(p, payload)
			w.pending = payload[n:]
			return n, nil
		case wsPing:
			if err := w.writeControl(wsPong, payload); err != nil {
				w.closeErr = err
				return 0, err
			}
		case wsPong:
			// Ignore unsolicited pongs.
		case wsClose:
			_ = w.writeControl(wsClose, nil)
			w.closeErr = io.EOF
			return 0, io.EOF
		case wsContinuation:
			// Simplified implementation: proxy servers use unfragmented binary
			// frames. If a continuation arrives, drain it rather than stall.
		}
	}
}

func (w *websocketConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	if err := w.writeData(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (w *websocketConn) writeData(payload []byte) error {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.writeFrame(wsBinary, payload)
}

func (w *websocketConn) writeControl(opcode byte, payload []byte) error {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.writeFrame(opcode, payload)
}

func (w *websocketConn) writeFrame(opcode byte, payload []byte) error {
	header := make([]byte, 0, 14)
	header = append(header, 0x80|opcode)

	length := len(payload)
	switch {
	case length < 126:
		header = append(header, 0x80|byte(length))
	case length <= 0xFFFF:
		header = append(header, 0x80|126, byte(length>>8), byte(length))
	default:
		header = append(header, 0x80|127)
		for i := 7; i >= 0; i-- {
			header = append(header, byte(length>>(8*i)))
		}
	}

	var mask [4]byte
	if _, err := io.ReadFull(rand.Reader, mask[:]); err != nil {
		return fmt.Errorf("websocket: generate mask: %w", err)
	}
	header = append(header, mask[:]...)

	if _, err := w.Conn.Write(header); err != nil {
		return err
	}
	if length == 0 {
		return nil
	}
	masked := make([]byte, length)
	for i := range payload {
		masked[i] = payload[i] ^ mask[i%4]
	}
	_, err := w.Conn.Write(masked)
	return err
}

func (w *websocketConn) readFrame() (byte, []byte, error) {
	first, err := w.br.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	opcode := first & 0x0F
	if opcode >= 0x3 && opcode <= 0x7 {
		return 0, nil, fmt.Errorf("websocket: reserved opcode %d", opcode)
	}
	second, err := w.br.ReadByte()
	if err != nil {
		return 0, nil, err
	}
	masked := second&0x80 != 0
	length := uint64(second & 0x7F)
	switch length {
	case 126:
		var b [2]byte
		if _, err := io.ReadFull(w.br, b[:]); err != nil {
			return 0, nil, err
		}
		length = uint64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err := io.ReadFull(w.br, b[:]); err != nil {
			return 0, nil, err
		}
		length = binary.BigEndian.Uint64(b[:])
		if length > 1<<31 {
			return 0, nil, fmt.Errorf("websocket: frame too large")
		}
	}

	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(w.br, mask[:]); err != nil {
			return 0, nil, err
		}
	}
	payload := make([]byte, int(length))
	if length > 0 {
		if _, err := io.ReadFull(w.br, payload); err != nil {
			return 0, nil, err
		}
		if masked {
			for i := range payload {
				payload[i] ^= mask[i%4]
			}
		}
	}
	return opcode, payload, nil
}

func (w *websocketConn) Close() error {
	return w.Conn.Close()
}

var _ net.Conn = (*websocketConn)(nil)
