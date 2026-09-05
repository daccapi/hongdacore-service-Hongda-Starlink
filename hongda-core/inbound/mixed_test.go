package inbound

import (
	"bytes"
	"testing"
)

func TestParseSOCKS5UDPHeaderIPv4(t *testing.T) {
	data := []byte{0, 0, 0, 0x01, 127, 0, 0, 1, 0, 53, 'x'}
	target, payload, ok := parseSOCKS5UDPHeader(data)
	if !ok {
		t.Fatal("parse failed")
	}
	if target != "127.0.0.1:53" {
		t.Fatalf("target = %q", target)
	}
	if string(payload) != "x" {
		t.Fatalf("payload = %q", payload)
	}
}

func TestSOCKS5UDPHeaderRoundTrip(t *testing.T) {
	header, ok := socks5UDPHeader("example.com:443")
	if !ok {
		t.Fatal("build failed")
	}
	want := append([]byte{0, 0, 0, 0x03, byte(len("example.com"))}, []byte("example.com")...)
	want = append(want, 0x01, 0xBB)
	if !bytes.Equal(header, want) {
		t.Fatalf("header = %x, want %x", header, want)
	}
}
