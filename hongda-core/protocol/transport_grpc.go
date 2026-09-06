package protocol

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"sync"

	"golang.org/x/net/http2"

	"hongda.local/hongda-core/model"
)

// gunConn implements the V2Ray "Gun" gRPC-lite stream framing over an HTTP/2
// bidirectional stream. It is deliberately minimal and does not depend on a
// full gRPC runtime.
type gunConn struct {
	net.Conn
	body      io.ReadCloser
	br        *bufio.Reader
	reqBody   io.WriteCloser
	respCh    <-chan *http.Response
	errCh     <-chan error
	initOnce  sync.Once
	initErr   error
	readMu    sync.Mutex
	writeMu   sync.Mutex
	closeOnce sync.Once
	readBuf   []byte
}

func grpcDial(ctx context.Context, base net.Conn, host string, port uint16, transport *model.TransportOptions) (net.Conn, error) {
	serviceName := strings.TrimSpace(transport.ServiceName)
	if serviceName == "" {
		serviceName = "GunService"
	}
	if !strings.HasPrefix(serviceName, "/") {
		serviceName = "/" + serviceName
	}

	scheme := "http"
	if isTLSConn(base) {
		scheme = "https"
	}
	authority := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	targetURL := &url.URL{Scheme: scheme, Host: authority, Path: serviceName}

	pr, pw := io.Pipe()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL.String(), pr)
	if err != nil {
		_ = base.Close()
		return nil, fmt.Errorf("grpc: create request: %w", err)
	}
	req.Host = authority
	req.Header.Set("Content-Type", "application/grpc")
	req.Header.Set("Te", "trailers")
	req.Header.Set("Grpc-Timeout", "0")

	rt := &http2.Transport{
		AllowHTTP:          true,
		DisableCompression: true,
		DialTLSContext: func(ctx context.Context, network, addr string, cfg *tls.Config) (net.Conn, error) {
			_ = ctx
			_ = network
			_ = addr
			_ = cfg
			return base, nil
		},
	}

	respCh := make(chan *http.Response, 1)
	errCh := make(chan error, 1)
	go func() {
		resp, err := rt.RoundTrip(req)
		if err != nil {
			errCh <- err
			return
		}
		respCh <- resp
	}()

	conn := &gunConn{
		Conn:    base,
		reqBody: pw,
		respCh:  respCh,
		errCh:   errCh,
	}
	return conn, nil
}

func isTLSConn(c net.Conn) bool {
	v := reflect.ValueOf(c)
	return v.MethodByName("ConnectionState").IsValid()
}

func (g *gunConn) Read(p []byte) (int, error) {
	g.readMu.Lock()
	defer g.readMu.Unlock()

	if len(p) == 0 {
		return 0, nil
	}
	if err := g.ensureResponse(); err != nil {
		return 0, err
	}
	if len(g.readBuf) > 0 {
		n := copy(p, g.readBuf)
		g.readBuf = g.readBuf[n:]
		return n, nil
	}

	for {
		payload, err := g.readMessage()
		if err != nil {
			return 0, err
		}
		if len(payload) == 0 {
			continue
		}
		n := copy(p, payload)
		g.readBuf = payload[n:]
		return n, nil
	}
}

func (g *gunConn) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	g.writeMu.Lock()
	defer g.writeMu.Unlock()
	if err := g.writeMessage(p); err != nil {
		return 0, err
	}
	return len(p), nil
}

func (g *gunConn) readMessage() ([]byte, error) {
	var header [5]byte
	if _, err := io.ReadFull(g.br, header[:]); err != nil {
		return nil, err
	}
	if header[0] != 0 {
		return nil, fmt.Errorf("grpc: compressed messages are not supported")
	}
	messageLen := binary.BigEndian.Uint32(header[1:5])
	if messageLen > 16*1024*1024 {
		return nil, fmt.Errorf("grpc: message too large: %d", messageLen)
	}
	message := make([]byte, int(messageLen))
	if _, err := io.ReadFull(g.br, message); err != nil {
		return nil, err
	}
	if len(message) == 0 {
		return nil, fmt.Errorf("grpc: empty protobuf message")
	}
	if message[0] != 0x0A {
		return nil, fmt.Errorf("grpc: invalid protobuf tag %x", message[0])
	}
	dataLen, n := binary.Uvarint(message[1:])
	if n <= 0 {
		return nil, fmt.Errorf("grpc: invalid protobuf length")
	}
	if dataLen > uint64(len(message)-1-n) {
		return nil, fmt.Errorf("grpc: protobuf length %d exceeds frame", dataLen)
	}
	return message[1+n : 1+n+int(dataLen)], nil
}

func (g *gunConn) writeMessage(payload []byte) error {
	u := make([]byte, binary.MaxVarintLen64)
	n := binary.PutUvarint(u, uint64(len(payload)))
	messageLen := 1 + n + len(payload)
	header := make([]byte, 5)
	header[0] = 0
	binary.BigEndian.PutUint32(header[1:5], uint32(messageLen))
	if _, err := g.reqBody.Write(header); err != nil {
		return err
	}
	if _, err := g.reqBody.Write([]byte{0x0A}); err != nil {
		return err
	}
	if _, err := g.reqBody.Write(u[:n]); err != nil {
		return err
	}
	if _, err := g.reqBody.Write(payload); err != nil {
		return err
	}
	return nil
}

func (g *gunConn) Close() error {
	var err error
	g.closeOnce.Do(func() {
		err = g.reqBody.Close()
		if g.body != nil {
			err = errors.Join(err, g.body.Close())
		}
		err = errors.Join(err, g.Conn.Close())
	})
	return err
}

func (g *gunConn) ensureResponse() error {
	g.initOnce.Do(func() {
		select {
		case resp := <-g.respCh:
			if resp == nil {
				g.initErr = fmt.Errorf("grpc: nil response")
				return
			}
			if resp.StatusCode != http.StatusOK {
				_ = resp.Body.Close()
				g.initErr = fmt.Errorf("grpc: unexpected status %d", resp.StatusCode)
				return
			}
			g.body = resp.Body
			g.br = bufio.NewReader(resp.Body)
		case g.initErr = <-g.errCh:
			if g.initErr == nil {
				g.initErr = fmt.Errorf("grpc: round trip failed")
			}
		}
	})
	return g.initErr
}

var _ net.Conn = (*gunConn)(nil)
