package protocol

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"testing"

	"hongda.local/hongda-core/model"
)

func TestWebSocketDialAndEcho(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	serverDone := make(chan error, 1)
	go func() {
		br := bufio.NewReader(server)
		req, err := http.ReadRequest(br)
		if err != nil {
			serverDone <- err
			return
		}
		accept := websocketAccept(req.Header.Get("Sec-WebSocket-Key"))
		response := "HTTP/1.1 101 Switching Protocols\r\n" +
			"Upgrade: websocket\r\n" +
			"Connection: Upgrade\r\n" +
			"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
		if _, err := io.WriteString(server, response); err != nil {
			serverDone <- err
			return
		}

		conn := &websocketConn{Conn: server, br: br}
		first, err := conn.br.ReadByte()
		if err != nil {
			serverDone <- err
			return
		}
		opcode := first & 0x0F
		second, err := conn.br.ReadByte()
		if err != nil {
			serverDone <- err
			return
		}
		length := uint64(second & 0x7F)
		var mask [4]byte
		if second&0x80 != 0 {
			if _, err := io.ReadFull(conn.br, mask[:]); err != nil {
				serverDone <- err
				return
			}
		}
		payload := make([]byte, int(length))
		if _, err := io.ReadFull(conn.br, payload); err != nil {
			serverDone <- err
			return
		}
		if second&0x80 != 0 {
			for i := range payload {
				payload[i] ^= mask[i%4]
			}
		}
		if string(payload) != "hello" {
			serverDone <- fmt.Errorf("payload = %q", payload)
			return
		}
		if err := conn.writeControl(opcode, payload); err != nil {
			serverDone <- err
			return
		}
		serverDone <- nil
	}()

	ctx := context.Background()
	conn, err := websocketDial(ctx, client, "example.com", 443, &model.TransportOptions{Type: "ws", Path: "/proxy"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 5)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "hello" {
		t.Fatalf("echo = %q", buf)
	}
	if err := <-serverDone; err != nil {
		t.Fatal(err)
	}
}
