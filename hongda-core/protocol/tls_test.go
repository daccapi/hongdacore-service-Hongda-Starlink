package protocol

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"net"
	"testing"

	utls "github.com/refraction-networking/utls"
)

func TestParseRealityPublicKey(t *testing.T) {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded := base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes())
	got, err := parseRealityPublicKey(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Bytes(), key.PublicKey().Bytes()) {
		t.Fatalf("public key mismatch: %x != %x", got.Bytes(), key.PublicKey().Bytes())
	}
}

func TestParseRealityShortID(t *testing.T) {
	got, err := parseRealityShortID("deadbeef")
	if err != nil {
		t.Fatal(err)
	}
	want := [8]byte{0xde, 0xad, 0xbe, 0xef}
	if got != want {
		t.Fatalf("short id = %x, want %x", got, want)
	}

	empty, err := parseRealityShortID("")
	if err != nil {
		t.Fatal(err)
	}
	if empty != ([8]byte{}) {
		t.Fatalf("empty short id = %x, want zeros", empty)
	}
}

func TestClientHelloIDFromString(t *testing.T) {
	id, err := clientHelloIDFromString("chrome")
	if err != nil {
		t.Fatal(err)
	}
	if id == utls.HelloGolang {
		t.Fatal("chrome should not map to HelloGolang")
	}
	if _, err := clientHelloIDFromString("not-a-real-fingerprint"); err == nil {
		t.Fatal("expected error for unsupported fingerprint")
	}
}

func TestRealityClientHelloShape(t *testing.T) {
	server, client := net.Pipe()
	defer server.Close()
	defer client.Close()

	u := utls.UClient(client, &utls.Config{
		ServerName:             "example.com",
		SessionTicketsDisabled: true,
	}, utls.HelloChrome_Auto)
	if err := u.BuildHandshakeState(); err != nil {
		t.Fatal(err)
	}
	hello := u.HandshakeState.Hello
	if len(hello.SessionId) != 32 {
		t.Fatalf("session id length = %d, want 32", len(hello.SessionId))
	}
	if len(hello.Raw) < realitySessionIDOffset+32 {
		t.Fatalf("raw client hello too short: %d", len(hello.Raw))
	}
	if u.HandshakeState.State13.KeyShareKeys == nil || u.HandshakeState.State13.KeyShareKeys.Ecdhe == nil {
		t.Fatal("expected X25519 key-share state")
	}
}
