package protocol

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestTUICAddress(t *testing.T) {
	got, err := tuicAddress("1.2.3.4:443")
	if err != nil {
		t.Fatal(err)
	}
	want := []byte{tuicAtypIPv4, 1, 2, 3, 4, 0x01, 0xBB}
	if !bytes.Equal(got, want) {
		t.Fatalf("address = %x, want %x", got, want)
	}
}

func TestParseTUICPacketFirstFragment(t *testing.T) {
	raw := make([]byte, 0, 32)
	raw = append(raw, tuicVersion, tuicCommandPacket)
	raw = binary.BigEndian.AppendUint16(raw, 0x1234)
	raw = binary.BigEndian.AppendUint16(raw, 0x0007)
	raw = append(raw, 0x01, 0x00)
	raw = binary.BigEndian.AppendUint16(raw, 7)
	addr, _ := tuicAddress("1.2.3.4:53")
	raw = append(raw, addr...)
	raw = append(raw, "payload"...)
	hdr, payload, err := parseTUICPacket(raw)
	if err != nil {
		t.Fatal(err)
	}
	if hdr.assocID != 0x1234 || hdr.packetID != 0x0007 || hdr.fragTotal != 1 || hdr.fragID != 0 {
		t.Fatalf("bad header: %+v", hdr)
	}
	if string(payload) != "payload" {
		t.Fatalf("payload = %q", payload)
	}
}
