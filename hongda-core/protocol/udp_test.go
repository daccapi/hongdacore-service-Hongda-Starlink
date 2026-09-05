package protocol

import (
	"bytes"
	"io"
	"net"
	"testing"
)

func TestVLESSUDPFraming(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	conn := &vlessUDPConn{Conn: client}
	go func() {
		_, _ = io.WriteString(server, "\x00\x02hi")
	}()
	buf := make([]byte, 2)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "hi" {
		t.Fatalf("read %q", buf)
	}

	go func() {
		header := make([]byte, 2)
		if _, err := io.ReadFull(server, header); err != nil {
			t.Error(err)
			return
		}
		if header[0] != 0 || header[1] != 3 {
			t.Errorf("header = %x", header)
		}
		payload := make([]byte, 3)
		if _, err := io.ReadFull(server, payload); err != nil {
			t.Error(err)
			return
		}
		if string(payload) != "bye" {
			t.Errorf("payload = %q", payload)
		}
	}()
	if _, err := conn.Write([]byte("bye")); err != nil {
		t.Fatal(err)
	}
}

func TestTrojanUDPFraming(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	target := trojanAddress("example.com", 53)
	conn := &trojanUDPConn{Conn: client, target: target}

	go func() {
		got, err := readTrojanAddress(server)
		if err != nil {
			t.Error(err)
			return
		}
		if !bytes.Equal(got, target) {
			t.Errorf("target = %x, want %x", got, target)
		}
		header := make([]byte, 2)
		if _, err := io.ReadFull(server, header); err != nil {
			t.Error(err)
			return
		}
		payload := make([]byte, 3)
		if _, err := io.ReadFull(server, payload); err != nil {
			t.Error(err)
			return
		}
		if string(payload) != "dns" {
			t.Errorf("payload = %q", payload)
		}
	}()
	if _, err := conn.Write([]byte("dns")); err != nil {
		t.Fatal(err)
	}
}
