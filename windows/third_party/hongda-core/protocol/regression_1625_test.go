package protocol

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	quic "github.com/quic-go/quic-go"
	"golang.org/x/net/http2"
	"hongda.local/hongda-core/model"
)

func TestRegressionWebSocketContinuationPreservesPayload(t *testing.T) {
	// One fragmented message: binary FIN=0 "hel", continuation FIN=1 "lo".
	wire := []byte{0x02, 3, 'h', 'e', 'l', 0x80, 2, 'l', 'o'}
	c := &websocketConn{br: bufio.NewReader(bytes.NewReader(wire))}
	got, err := io.ReadAll(c)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "hello" {
		t.Fatalf("fragmented message lost bytes: got %q, want hello", got)
	}
}

func TestRegressionGRPCEmptyMessageReturnsErrorInsteadOfPanic(t *testing.T) {
	defer func() {
		if p := recover(); p != nil {
			t.Fatalf("empty gRPC message panicked: %v", p)
		}
	}()
	c := &gunConn{br: bufio.NewReader(bytes.NewReader([]byte{0, 0, 0, 0, 0}))}
	_, _ = c.readMessage()
}

func TestRegressionGRPCEmptyDataDoesNotDeadlock(t *testing.T) {
	// Empty protobuf data (0a00) followed by one byte (0a0178).
	wire := []byte{0, 0, 0, 0, 2, 0x0a, 0, 0, 0, 0, 0, 3, 0x0a, 1, 'x'}
	c := &gunConn{br: bufio.NewReader(bytes.NewReader(wire))}
	c.initOnce.Do(func() {})
	done := make(chan error, 1)
	go func() { _, err := c.Read(make([]byte, 1)); done <- err }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(150 * time.Millisecond):
		t.Fatal("Read deadlocked on empty data while holding readMu")
	}
}

func TestRegressionGRPCSurvivesDialContextCancellation(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	serveDone := make(chan struct{})
	go func() {
		defer close(serveDone)
		(&http2.Server{}).ServeConn(server, &http2.ServeConnOpts{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			packet := make([]byte, 8)
			if _, err := io.ReadFull(r.Body, packet); err != nil {
				return
			}
			w.Header().Set("Content-Type", "application/grpc")
			w.WriteHeader(200)
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		})})
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	conn, err := grpcDial(ctx, client, "localhost", 443, &model.TransportOptions{ServiceName: "svc"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err = conn.Write([]byte{'x'}); err != nil {
		t.Fatal(err)
	}
	if err = conn.(*gunConn).ensureResponse(); err != nil {
		t.Fatal(err)
	}
	cancel() // Router.dialRouted defers cancel immediately after DialContext.
	done := make(chan error, 1)
	go func() { _, e := conn.Read(make([]byte, 1)); done <- e }()
	select {
	case e := <-done:
		t.Fatalf("established gRPC stream stopped when dial context ended: %v", e)
	case <-time.After(150 * time.Millisecond):
	}
}

func TestRegressionClosedQUICSessionMustNotBeReused(t *testing.T) {
	certificateServer := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	certificate := certificateServer.TLS.Certificates[0]
	certificateServer.Close()
	listener, err := quic.ListenAddr("127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h3"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	accepted := make(chan *quic.Conn, 1)
	go func() { conn, _ := listener.Accept(ctx); accepted <- conn }()
	conn, err := quic.DialAddr(ctx, listener.Addr().String(), &tls.Config{InsecureSkipVerify: true, NextProtos: []string{"h3"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	serverConn := <-accepted
	if serverConn != nil {
		defer serverConn.CloseWithError(0, "")
	}
	conn.CloseWithError(0, "simulate closed tunnel")
	<-conn.Context().Done()
	h := &Hysteria2{sess: &hysteria2Session{conn: conn}}
	hSession, hErr := h.session(ctx)
	if hErr == nil && hSession.conn == conn {
		t.Error("Hysteria2 returned the terminated cached QUIC session")
	}
	tu := &TUIC{sess: &tuicSession{conn: conn}}
	tSession, tErr := tu.session(ctx)
	if tErr == nil && tSession.conn == conn {
		t.Error("TUIC returned the terminated cached QUIC session")
	}
}

func TestRegressionGRPCShouldDialServerOnlyOnce(t *testing.T) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	accepted := make(chan net.Conn, 4)
	go func() {
		for {
			c, e := listener.Accept()
			if e != nil {
				return
			}
			accepted <- c
		}
	}()
	host, portString, _ := net.SplitHostPort(listener.Addr().String())
	port, _ := strconv.Atoi(portString)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	c, err := dialTransportConn(ctx, host, uint16(port), nil, &model.TransportOptions{Type: "grpc", ServiceName: "svc"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	count := 0
	deadline := time.NewTimer(150 * time.Millisecond)
	defer deadline.Stop()
	for {
		select {
		case peer := <-accepted:
			count++
			peer.Close()
		case <-deadline.C:
			if count != 1 {
				t.Fatalf("one gRPC dial opened %d TCP connections; the first base connection is discarded without Close", count)
			}
			return
		}
	}
}

func TestRegressionWebSocketHandshakeHonorsTimeout(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()
	read := make(chan struct{})
	go func() { _, _ = http.ReadRequest(bufio.NewReader(server)); close(read) }()
	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := websocketDial(ctx, client, "localhost", 443, &model.TransportOptions{Path: "/"})
		done <- err
	}()
	<-read
	<-ctx.Done()
	select {
	case err := <-done:
		if err == nil {
			t.Error("handshake should return timeout")
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("WebSocket handshake is still blocked after context deadline")
	}
	server.Close()
}
