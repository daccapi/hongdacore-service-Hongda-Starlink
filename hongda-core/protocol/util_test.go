package protocol

import (
	"bytes"
	"testing"
)

func TestVLESSAddressIPv4(t *testing.T) {
	got := vlessAddress("1.2.3.4", 443)
	want := []byte{0x01, 0xBB, 0x01, 0x01, 0x02, 0x03, 0x04}
	if !bytes.Equal(got, want) {
		t.Fatalf("vless ipv4 = %x, want %x", got, want)
	}
}

func TestVLESSAddressDomain(t *testing.T) {
	got := vlessAddress("example.com", 443)
	want := append([]byte{0x01, 0xBB, 0x02, 0x0B}, []byte("example.com")...)
	if !bytes.Equal(got, want) {
		t.Fatalf("vless domain = %x, want %x", got, want)
	}
}

func TestTrojanAddressDomain(t *testing.T) {
	got := trojanAddress("example.com", 443)
	want := append(append([]byte{0x03, 0x0B}, []byte("example.com")...), 0x01, 0xBB)
	if !bytes.Equal(got, want) {
		t.Fatalf("trojan domain = %x, want %x", got, want)
	}
}

func TestParseUUID(t *testing.T) {
	got, err := parseUUID("01234567-89ab-cdef-0123-456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	want := []byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef}
	if !bytes.Equal(got, want) {
		t.Fatalf("uuid = %x, want %x", got, want)
	}
}
