package route

import (
	"encoding/binary"
	"net"
	"testing"
)

func TestBuildDNSQueryName(t *testing.T) {
	q := buildDNSQuery("www.example.com", 1)
	if len(q) < 20 {
		t.Fatalf("query too short: %d", len(q))
	}
	if got := q[len(q)-4:]; binary.BigEndian.Uint16(got[:2]) != 1 || binary.BigEndian.Uint16(got[2:]) != 1 {
		t.Fatalf("bad query trailer %x", got)
	}
}

func TestParseDNSAnswersA(t *testing.T) {
	name := []byte{3, 'w', 'w', 'w', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 3, 'c', 'o', 'm', 0}
	packet := make([]byte, 12)
	binary.BigEndian.PutUint16(packet[4:6], 1)
	binary.BigEndian.PutUint16(packet[6:8], 1)
	packet = append(packet, name...)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = append(packet, 0xC0, 0x0C)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = binary.BigEndian.AppendUint16(packet, 1)
	packet = binary.BigEndian.AppendUint32(packet, 60)
	packet = binary.BigEndian.AppendUint16(packet, 4)
	packet = append(packet, 1, 2, 3, 4)

	ips, err := parseDNSAnswers(packet, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(ips) != 1 || !ips[0].Equal(net.IP{1, 2, 3, 4}) {
		t.Fatalf("ips = %v", ips)
	}
}
