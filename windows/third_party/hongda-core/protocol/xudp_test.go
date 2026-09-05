package protocol

import (
	"bytes"
	"io"
	"net"
	"testing"
)

func TestBuildXUDPNewFrame(t *testing.T) {
	globalID := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	frame := buildXUDPNew("example.com", 53, globalID, []byte("query"))

	r := bytes.NewReader(frame)
	got, err := decodeXUDPFrame(r)
	if err != nil {
		t.Fatal(err)
	}
	if got.status != muxStatusNew {
		t.Fatalf("status = %d, want new", got.status)
	}
	if got.host != "example.com" || got.port != 53 {
		t.Fatalf("target = %s:%d, want example.com:53", got.host, got.port)
	}
	if !bytes.Equal(got.globalID, globalID) {
		t.Fatalf("global id = %x, want %x", got.globalID, globalID)
	}
	if string(got.data) != "query" {
		t.Fatalf("data = %q", got.data)
	}
}

func TestBuildXUDPKeepFrame(t *testing.T) {
	frame := buildXUDPKeep("1.2.3.4", 443, []byte("hello"))
	r := bytes.NewReader(frame)
	got, err := decodeXUDPFrame(r)
	if err != nil {
		t.Fatal(err)
	}
	if got.status != muxStatusKeep {
		t.Fatalf("status = %d, want keep", got.status)
	}
	if got.host != "1.2.3.4" || got.port != 443 {
		t.Fatalf("target = %s:%d, want 1.2.3.4:443", got.host, got.port)
	}
	if got.globalID != nil {
		t.Fatalf("keep frame should not carry global id: %x", got.globalID)
	}
	if string(got.data) != "hello" {
		t.Fatalf("data = %q", got.data)
	}
}

func TestXUDPConnWriteRead(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	conn, err := newXUDPConn(client, "example.com", 53)
	if err != nil {
		t.Fatal(err)
	}

	// Server reads the first datagram as a New frame.
	newDone := make(chan error, 1)
	go func() {
		f, err := decodeXUDPFrame(server)
		if err != nil {
			newDone <- err
			return
		}
		if f.status != muxStatusNew || string(f.data) != "first" {
			newDone <- io.ErrUnexpectedEOF
			return
		}
		newDone <- nil
	}()
	if _, err := conn.Write([]byte("first")); err != nil {
		t.Fatal(err)
	}
	if err := <-newDone; err != nil {
		t.Fatal(err)
	}

	// Second datagram must be a Keep frame.
	keepDone := make(chan error, 1)
	go func() {
		f, err := decodeXUDPFrame(server)
		if err != nil {
			keepDone <- err
			return
		}
		if f.status != muxStatusKeep || string(f.data) != "second" {
			keepDone <- io.ErrUnexpectedEOF
			return
		}
		keepDone <- nil
	}()
	if _, err := conn.Write([]byte("second")); err != nil {
		t.Fatal(err)
	}
	if err := <-keepDone; err != nil {
		t.Fatal(err)
	}

	// Read path: server sends a Keep frame back to the client.
	readDone := make(chan error, 1)
	go func() {
		buf := make([]byte, 32)
		n, err := conn.Read(buf)
		if err != nil {
			readDone <- err
			return
		}
		if string(buf[:n]) != "reply" {
			readDone <- io.ErrUnexpectedEOF
			return
		}
		readDone <- nil
	}()
	reply := buildXUDPKeep("example.com", 53, []byte("reply"))
	if _, err := server.Write(reply); err != nil {
		t.Fatal(err)
	}
	if err := <-readDone; err != nil {
		t.Fatal(err)
	}
}

func TestXUDPCloseSendsEnd(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	conn, err := newXUDPConn(client, "example.com", 53)
	if err != nil {
		t.Fatal(err)
	}

	endDone := make(chan error, 1)
	go func() {
		f, err := decodeXUDPFrame(server)
		if err != nil {
			endDone <- err
			return
		}
		if f.status != muxStatusEnd {
			endDone <- io.ErrUnexpectedEOF
			return
		}
		endDone <- nil
	}()
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-endDone; err != nil {
		t.Fatal(err)
	}
}

func TestParseXUDPTargetIPv6(t *testing.T) {
	addr := muxAddressBytes("2001:db8::1")
	rest := append([]byte{muxNetworkUDP, 0x01, 0xBB}, addr...)
	rest = append(rest, 1, 2, 3, 4, 5, 6, 7, 8)
	host, port, globalID, err := parseXUDPTarget(rest, muxStatusNew)
	if err != nil {
		t.Fatal(err)
	}
	if host != "2001:db8::1" || port != 443 {
		t.Fatalf("target = %s:%d", host, port)
	}
	if !bytes.Equal(globalID, []byte{1, 2, 3, 4, 5, 6, 7, 8}) {
		t.Fatalf("global id = %x", globalID)
	}
}
