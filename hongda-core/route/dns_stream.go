package route

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"time"
)

// ServeDNSStream handles the RFC 1035 two-byte length framing used by DNS over
// TCP. Every plaintext query is exchanged through the configured encrypted
// resolver, closing the TCP/53 leak left by UDP-only interception.
func (r *Router) ServeDNSStream(ctx context.Context, conn net.Conn) error {
	var lengthBytes [2]byte
	for {
		if err := conn.SetReadDeadline(time.Now().Add(2 * time.Minute)); err != nil {
			if isClosedStreamError(err) {
				return nil
			}
			return err
		}
		if _, err := io.ReadFull(conn, lengthBytes[:]); err != nil {
			if isClosedStreamError(err) {
				return nil
			}
			return fmt.Errorf("read TCP DNS length: %w", err)
		}
		queryLength := int(binary.BigEndian.Uint16(lengthBytes[:]))
		if queryLength == 0 {
			return fmt.Errorf("empty TCP DNS query")
		}
		query := make([]byte, queryLength)
		if _, err := io.ReadFull(conn, query); err != nil {
			return fmt.Errorf("read TCP DNS query: %w", err)
		}

		exchangeContext, cancel := context.WithTimeout(ctx, 12*time.Second)
		response, err := r.ExchangeDNS(exchangeContext, query)
		cancel()
		if err != nil {
			return err
		}
		if len(response) > 65535 {
			return fmt.Errorf("TCP DNS response exceeds 65535 bytes")
		}
		frame := make([]byte, len(response)+2)
		binary.BigEndian.PutUint16(frame[:2], uint16(len(response)))
		copy(frame[2:], response)
		if err := conn.SetWriteDeadline(time.Now().Add(12 * time.Second)); err != nil {
			return err
		}
		if err := writeAll(conn, frame); err != nil {
			return fmt.Errorf("write TCP DNS response: %w", err)
		}
		r.AddUpload(int64(queryLength + 2))
		r.AddDownload(int64(len(response) + 2))
	}
}

func isClosedStreamError(err error) bool {
	return errors.Is(err, io.EOF) || errors.Is(err, io.ErrClosedPipe) || errors.Is(err, net.ErrClosed)
}

func writeAll(writer io.Writer, data []byte) error {
	for len(data) > 0 {
		n, err := writer.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		data = data[n:]
	}
	return nil
}
