package protocol

import (
	"context"
	"crypto/tls"
	quic "github.com/quic-go/quic-go"
	"github.com/quic-go/quic-go/http3"
	"hongda.local/hongda-core/model"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"sync"
	"testing"
	"time"
)

// A loopback QUIC/auth fixture checks session lifecycle, not interoperability
// with a production TUIC/Hysteria2 server. No TUN or system settings are touched.
func TestQUICSessionSingleFlightAndReconnect(t *testing.T) {
	for _, kind := range []string{"tuic", "hysteria2"} {
		t.Run(kind, func(t *testing.T) {
			certServer := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
			certificate := certServer.TLS.Certificates[0]
			certServer.Close()
			listener, err := quic.ListenAddr("127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h3"}}, &quic.Config{EnableDatagrams: true})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			httpServer := &http3.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(hysteria2StatusOK) })}
			defer httpServer.Close()
			go func() {
				for {
					conn, err := listener.Accept(ctx)
					if err != nil {
						return
					}
					go func() {
						defer conn.CloseWithError(0, "test end")
						if kind == "hysteria2" {
							_ = httpServer.ServeQUICConn(conn)
							return
						}
						stream, err := conn.AcceptUniStream(ctx)
						if err == nil {
							_, _ = io.Copy(io.Discard, stream)
						}
						select {
						case <-conn.Context().Done():
						case <-ctx.Done():
						}
					}()
				}
			}()
			host, portText, _ := net.SplitHostPort(listener.Addr().String())
			port, _ := strconv.Atoi(portText)
			node := model.Node{ID: "test", Server: host, Port: uint16(port), Auth: map[string]string{"uuid": "00000000-0000-0000-0000-000000000001", "password": "test-only"}, TLS: &model.TLSOptions{Enabled: true, Insecure: true}}
			var acquire func() (*quic.Conn, error)
			if kind == "tuic" {
				ob, err := NewTUIC(node)
				if err != nil {
					t.Fatal(err)
				}
				defer ob.Close()
				acquire = func() (*quic.Conn, error) {
					s, e := ob.session(ctx)
					if e != nil {
						return nil, e
					}
					return s.conn, nil
				}
			} else {
				ob, err := NewHysteria2(node)
				if err != nil {
					t.Fatal(err)
				}
				defer ob.Close()
				acquire = func() (*quic.Conn, error) {
					s, e := ob.session(ctx)
					if e != nil {
						return nil, e
					}
					return s.conn, nil
				}
			}
			var wg sync.WaitGroup
			connections := make(chan *quic.Conn, 8)
			errors := make(chan error, 8)
			for range 8 {
				wg.Add(1)
				go func() {
					defer wg.Done()
					conn, err := acquire()
					if err != nil {
						errors <- err
					} else {
						connections <- conn
					}
				}()
			}
			wg.Wait()
			close(errors)
			close(connections)
			for err := range errors {
				t.Fatal(err)
			}
			var first *quic.Conn
			for conn := range connections {
				if first == nil {
					first = conn
				} else if conn != first {
					t.Fatal("parallel callers established redundant QUIC sessions")
				}
			}
			if first == nil {
				t.Fatal("no session")
			}
			first.CloseWithError(0, "simulate disconnect")
			<-first.Context().Done()
			second, err := acquire()
			if err != nil {
				t.Fatal(err)
			}
			if first == second || second.Context().Err() != nil {
				t.Fatal("did not replace dead QUIC session")
			}
		})
	}
}
