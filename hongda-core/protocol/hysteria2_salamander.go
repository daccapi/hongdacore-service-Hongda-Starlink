package protocol

import (
	"crypto/rand"
	"fmt"
	"io"
	"net"

	"golang.org/x/crypto/blake2b"
)

const hysteria2SalamanderSaltLen = 8

// salamanderPacketConn applies the Hysteria2 Salamander packet transform to a
// UDP socket. Every datagram uses an independent random salt and a BLAKE2b-256
// derived XOR key, so QUIC only sees the restored packet bytes.
type salamanderPacketConn struct {
	net.PacketConn
	password []byte
}

func newSalamanderPacketConn(conn net.PacketConn, password string) (*salamanderPacketConn, error) {
	if conn == nil {
		return nil, fmt.Errorf("hysteria2 salamander: packet connection is nil")
	}
	if password == "" {
		return nil, fmt.Errorf("hysteria2 salamander: password is required")
	}
	return &salamanderPacketConn{
		PacketConn: conn,
		password:   []byte(password),
	}, nil
}

func (c *salamanderPacketConn) ReadFrom(p []byte) (int, net.Addr, error) {
	if len(p) == 0 {
		return 0, nil, nil
	}
	packet := make([]byte, len(p)+hysteria2SalamanderSaltLen)
	for {
		n, addr, err := c.PacketConn.ReadFrom(packet)
		if err != nil {
			return 0, addr, err
		}
		if n <= hysteria2SalamanderSaltLen {
			continue
		}
		payloadLen := n - hysteria2SalamanderSaltLen
		key := salamanderKey(c.password, packet[:hysteria2SalamanderSaltLen])
		for i := 0; i < payloadLen; i++ {
			p[i] = packet[hysteria2SalamanderSaltLen+i] ^ key[i%len(key)]
		}
		return payloadLen, addr, nil
	}
}

func (c *salamanderPacketConn) WriteTo(p []byte, addr net.Addr) (int, error) {
	packet := make([]byte, hysteria2SalamanderSaltLen+len(p))
	if _, err := io.ReadFull(rand.Reader, packet[:hysteria2SalamanderSaltLen]); err != nil {
		return 0, fmt.Errorf("hysteria2 salamander: generate salt: %w", err)
	}
	key := salamanderKey(c.password, packet[:hysteria2SalamanderSaltLen])
	for i, value := range p {
		packet[hysteria2SalamanderSaltLen+i] = value ^ key[i%len(key)]
	}
	n, err := c.PacketConn.WriteTo(packet, addr)
	if err != nil {
		return 0, err
	}
	if n != len(packet) {
		return 0, io.ErrShortWrite
	}
	return len(p), nil
}

func salamanderKey(password, salt []byte) [blake2b.Size256]byte {
	material := make([]byte, 0, len(password)+len(salt))
	material = append(material, password...)
	material = append(material, salt...)
	return blake2b.Sum256(material)
}
