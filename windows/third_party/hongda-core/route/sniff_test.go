package route

import (
	"encoding/binary"
	"testing"
)

func TestParseTLSClientHelloSNI(t *testing.T) {
	host := []byte("www.youtube.com")
	serverName := make([]byte, 0, len(host)+5)
	serverName = binary.BigEndian.AppendUint16(serverName, uint16(len(host)+3))
	serverName = append(serverName, 0)
	serverName = binary.BigEndian.AppendUint16(serverName, uint16(len(host)))
	serverName = append(serverName, host...)
	extensions := binary.BigEndian.AppendUint16(nil, 0)
	extensions = binary.BigEndian.AppendUint16(extensions, uint16(len(serverName)))
	extensions = append(extensions, serverName...)

	body := []byte{0x03, 0x03}
	body = append(body, make([]byte, 32)...)
	body = append(body, 0)
	body = binary.BigEndian.AppendUint16(body, 2)
	body = append(body, 0x13, 0x01)
	body = append(body, 1, 0)
	body = binary.BigEndian.AppendUint16(body, uint16(len(extensions)))
	body = append(body, extensions...)
	record := []byte{1, byte(len(body) >> 16), byte(len(body) >> 8), byte(len(body))}
	record = append(record, body...)

	if got := parseTLSClientHelloSNI(record); got != "www.youtube.com" {
		t.Fatalf("SNI = %q, want www.youtube.com", got)
	}
}
