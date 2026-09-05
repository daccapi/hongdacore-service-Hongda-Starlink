package route

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"

	"hongda.local/hongda-core/model"
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

func TestLookupDoHUsesConfiguredDetourDialer(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, err := base64.RawURLEncoding.DecodeString(r.URL.Query().Get("dns"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		qtype := binary.BigEndian.Uint16(data[len(data)-4 : len(data)-2])
		response := append([]byte(nil), data...)
		response[2], response[3] = 0x81, 0x80
		binary.BigEndian.PutUint16(response[6:8], 1)
		response = append(response, 0xC0, 0x0C)
		response = binary.BigEndian.AppendUint16(response, qtype)
		response = binary.BigEndian.AppendUint16(response, 1)
		response = binary.BigEndian.AppendUint32(response, 60)
		if qtype == 1 {
			response = binary.BigEndian.AppendUint16(response, 4)
			response = append(response, 203, 0, 113, 10)
		} else {
			response = binary.BigEndian.AppendUint16(response, 16)
			response = append(response, net.ParseIP("2001:db8::10").To16()...)
		}
		w.Header().Set("Content-Type", "application/dns-message")
		_, _ = w.Write(response)
	}))
	defer server.Close()

	dialCount := 0
	dialer := func(ctx context.Context, network, address string) (net.Conn, error) {
		dialCount++
		return (&net.Dialer{}).DialContext(ctx, network, address)
	}
	ips, err := lookupDoH(context.Background(), model.DNSOptions{Server: server.URL}, "example.com", dialer)
	if err != nil {
		t.Fatal(err)
	}
	if dialCount != 2 {
		t.Fatalf("detour dial count = %d, want 2", dialCount)
	}
	if len(ips) != 2 {
		t.Fatalf("ips = %v", ips)
	}
}
