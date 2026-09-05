package protocol

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"testing"

	"github.com/quic-go/quic-go/quicvarint"
)

func TestWriteHysteria2TCPRequest(t *testing.T) {
	var buf bytes.Buffer
	if err := writeHysteria2TCPRequest(&buf, "example.com:443"); err != nil {
		t.Fatal(err)
	}
	raw := buf.Bytes()
	frame, n, err := quicvarint.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if frame != hysteria2FrameTCPRequest {
		t.Fatalf("frame = %#x, want %#x", frame, hysteria2FrameTCPRequest)
	}
	raw = raw[n:]
	addrLen, n, err := quicvarint.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	raw = raw[n:]
	if int(addrLen) != len("example.com:443") {
		t.Fatalf("addr length = %d", addrLen)
	}
	if string(raw[:addrLen]) != "example.com:443" {
		t.Fatalf("address = %q", raw[:addrLen])
	}
	raw = raw[addrLen:]
	padding, _, err := quicvarint.Parse(raw)
	if err != nil {
		t.Fatal(err)
	}
	if padding != 0 {
		t.Fatalf("padding = %d, want 0", padding)
	}
}

func TestReadHysteria2TCPResponseOK(t *testing.T) {
	raw := []byte{0x00, 0x00, 0x00}
	if err := readHysteria2TCPResponse(bufio.NewReader(bytes.NewReader(raw))); err != nil {
		t.Fatal(err)
	}
}

func TestParseHysteria2UDPMessage(t *testing.T) {
	raw := make([]byte, 0, 32)
	raw = binary.BigEndian.AppendUint32(raw, 0x01020304)
	raw = binary.BigEndian.AppendUint16(raw, 0x1234)
	raw = append(raw, 0x00, 0x01)
	raw = quicvarint.Append(raw, uint64(len("1.2.3.4:53")))
	raw = append(raw, "1.2.3.4:53"...)
	raw = append(raw, "payload"...)
	hdr, addr, payload, err := parseHysteria2UDPMessage(raw)
	if err != nil {
		t.Fatal(err)
	}
	if hdr.sessionID != 0x01020304 || hdr.packetID != 0x1234 {
		t.Fatalf("bad header: %+v", hdr)
	}
	if string(addr) != "1.2.3.4:53" || string(payload) != "payload" {
		t.Fatalf("addr=%q payload=%q", addr, payload)
	}
}
