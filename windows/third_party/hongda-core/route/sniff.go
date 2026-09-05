package route

import (
	"bufio"
	"encoding/binary"
	"net"
	"strings"
	"time"
)

const maxClientHelloSize = 64 * 1024

type sniffedConn struct {
	net.Conn
	reader *bufio.Reader
}

func (c *sniffedConn) Read(buffer []byte) (int, error) {
	return c.reader.Read(buffer)
}

// SniffTLSHost peeks at the first TLS ClientHello without consuming it. The
// returned connection replays every buffered byte to the upstream copy loop.
func SniffTLSHost(conn net.Conn, timeout time.Duration) (net.Conn, string) {
	reader := bufio.NewReaderSize(conn, maxClientHelloSize)
	wrapped := &sniffedConn{Conn: conn, reader: reader}
	_ = conn.SetReadDeadline(time.Now().Add(timeout))
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()
	header, err := reader.Peek(5)
	if err != nil || header[0] != 22 {
		return wrapped, ""
	}
	recordLength := int(binary.BigEndian.Uint16(header[3:5]))
	if recordLength < 4 || recordLength+5 > maxClientHelloSize {
		return wrapped, ""
	}
	record, err := reader.Peek(recordLength + 5)
	if err != nil {
		return wrapped, ""
	}
	return wrapped, parseTLSClientHelloSNI(record[5:])
}

func parseTLSClientHelloSNI(record []byte) string {
	if len(record) < 4 || record[0] != 1 {
		return ""
	}
	handshakeLength := int(record[1])<<16 | int(record[2])<<8 | int(record[3])
	if handshakeLength+4 > len(record) {
		return ""
	}
	body := record[4 : handshakeLength+4]
	if len(body) < 35 {
		return ""
	}
	offset := 34
	sessionLength := int(body[offset])
	offset++
	if offset+sessionLength+2 > len(body) {
		return ""
	}
	offset += sessionLength
	cipherLength := int(binary.BigEndian.Uint16(body[offset : offset+2]))
	offset += 2
	if offset+cipherLength+1 > len(body) {
		return ""
	}
	offset += cipherLength
	compressionLength := int(body[offset])
	offset++
	if offset+compressionLength+2 > len(body) {
		return ""
	}
	offset += compressionLength
	extensionsLength := int(binary.BigEndian.Uint16(body[offset : offset+2]))
	offset += 2
	end := offset + extensionsLength
	if end > len(body) {
		return ""
	}
	for offset+4 <= end {
		extensionType := binary.BigEndian.Uint16(body[offset : offset+2])
		extensionLength := int(binary.BigEndian.Uint16(body[offset+2 : offset+4]))
		offset += 4
		if offset+extensionLength > end {
			return ""
		}
		if extensionType == 0 && extensionLength >= 5 {
			data := body[offset : offset+extensionLength]
			listLength := int(binary.BigEndian.Uint16(data[:2]))
			if listLength+2 <= len(data) {
				position := 2
				for position+3 <= listLength+2 {
					nameType := data[position]
					nameLength := int(binary.BigEndian.Uint16(data[position+1 : position+3]))
					position += 3
					if position+nameLength > len(data) {
						return ""
					}
					if nameType == 0 {
						return strings.ToLower(strings.TrimSuffix(string(data[position:position+nameLength]), "."))
					}
					position += nameLength
				}
			}
		}
		offset += extensionLength
	}
	return ""
}
