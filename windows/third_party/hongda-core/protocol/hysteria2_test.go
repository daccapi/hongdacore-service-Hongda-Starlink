package protocol

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"net"
	"testing"
	"time"

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

func TestSalamanderPacketConnRoundTrip(t *testing.T) {
	serverUDP, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer serverUDP.Close()
	clientUDP, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer clientUDP.Close()
	server, err := newSalamanderPacketConn(serverUDP, "shared-secret")
	if err != nil {
		t.Fatal(err)
	}
	client, err := newSalamanderPacketConn(clientUDP, "shared-secret")
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(2 * time.Second)
	_ = server.SetDeadline(deadline)
	_ = client.SetDeadline(deadline)
	request := []byte("hysteria2-quic-packet")
	if n, err := client.WriteTo(request, serverUDP.LocalAddr()); err != nil || n != len(request) {
		t.Fatalf("client write = %d, %v", n, err)
	}
	buf := make([]byte, 1500)
	n, clientAddr, err := server.ReadFrom(buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf[:n], request) {
		t.Fatalf("server plaintext = %x", buf[:n])
	}

	response := []byte("hysteria2-response")
	if n, err := server.WriteTo(response, clientAddr); err != nil || n != len(response) {
		t.Fatalf("server write = %d, %v", n, err)
	}
	n, _, err = client.ReadFrom(buf)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf[:n], response) {
		t.Fatalf("client plaintext = %x", buf[:n])
	}
}

func TestSalamanderKeyDependsOnSaltAndPassword(t *testing.T) {
	first := salamanderKey([]byte("password"), []byte("12345678"))
	second := salamanderKey([]byte("password"), []byte("87654321"))
	third := salamanderKey([]byte("different"), []byte("12345678"))
	if first == second || first == third {
		t.Fatal("salamander key did not change with salt or password")
	}
}
