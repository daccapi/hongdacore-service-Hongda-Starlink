package protocol

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	utls "github.com/refraction-networking/utls"

	"hongda.local/hongda-core/model"
)

const (
	realityClientVersionMajor = 1
	realityClientVersionMinor = 6
	realityClientVersionPatch = 8
	realitySessionIDOffset    = 39 // TLS record header + version + random + session-id length
)

// dialTLS is the shared TLS entrypoint for VLESS and Trojan. It chooses the
// right path from the unified TLSOptions:
//
//   - Reality enabled  -> REALITY + uTLS authenticated handshake
//   - uTLS fingerprint -> uTLS fingerprint-masked TLS
//   - otherwise        -> standard Go TLS
func dialTLS(ctx context.Context, host string, port uint16, opts *model.TLSOptions) (net.Conn, error) {
	return dialTLSWithNextProtos(ctx, host, port, opts, []string{"http/1.1"})
}

func dialTLSWithNextProtos(ctx context.Context, host string, port uint16, opts *model.TLSOptions, nextProtos []string) (net.Conn, error) {
	if opts == nil || !opts.Enabled {
		return dialRawTCP(ctx, host, port)
	}
	if opts.Reality != nil && opts.Reality.Enabled {
		return dialRealityTLSWithNextProtos(ctx, host, port, opts, nextProtos)
	}
	if opts.UTLSFingerprint != "" && !isPlainTLSFingerprint(opts.UTLSFingerprint) {
		return dialUTLSWithNextProtos(ctx, host, port, opts, nextProtos)
	}
	return dialStandardTLSWithNextProtos(ctx, host, port, opts, nextProtos)
}

func dialRawTCP(ctx context.Context, host string, port uint16) (net.Conn, error) {
	addr := net.JoinHostPort(host, strconv.Itoa(int(port)))
	var d net.Dialer
	return d.DialContext(ctx, "tcp", addr)
}

func dialStandardTLSWithNextProtos(ctx context.Context, host string, port uint16, opts *model.TLSOptions, nextProtos []string) (net.Conn, error) {
	raw, err := dialRawTCP(ctx, host, port)
	if err != nil {
		return nil, err
	}
	serverName := opts.ServerName
	if serverName == "" {
		serverName = host
	}
	cfg := &tls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: opts.Insecure,
		NextProtos:         nextProtos,
	}
	conn := tls.Client(raw, cfg)
	if err := conn.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return conn, nil
}

func dialUTLS(ctx context.Context, host string, port uint16, opts *model.TLSOptions) (net.Conn, error) {
	return dialUTLSWithNextProtos(ctx, host, port, opts, []string{"http/1.1"})
}

func dialUTLSWithNextProtos(ctx context.Context, host string, port uint16, opts *model.TLSOptions, nextProtos []string) (net.Conn, error) {
	raw, err := dialRawTCP(ctx, host, port)
	if err != nil {
		return nil, err
	}
	serverName := opts.ServerName
	if serverName == "" {
		serverName = host
	}
	helloID, err := clientHelloIDFromString(opts.UTLSFingerprint)
	if err != nil {
		_ = raw.Close()
		return nil, err
	}
	cfg := &utls.Config{
		ServerName:         serverName,
		InsecureSkipVerify: opts.Insecure,
		NextProtos:         nextProtos,
	}
	conn := utls.UClient(raw, cfg, helloID)
	if err := conn.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return conn, nil
}

func dialRealityTLS(ctx context.Context, host string, port uint16, opts *model.TLSOptions) (net.Conn, error) {
	return dialRealityTLSWithNextProtos(ctx, host, port, opts, []string{"http/1.1"})
}

func dialRealityTLSWithNextProtos(ctx context.Context, host string, port uint16, opts *model.TLSOptions, nextProtos []string) (net.Conn, error) {
	reality := opts.Reality
	if reality == nil {
		return nil, fmt.Errorf("reality options are nil")
	}
	if opts.ServerName == "" {
		return nil, fmt.Errorf("reality requires server_name")
	}
	if strings.TrimSpace(reality.PublicKey) == "" {
		return nil, fmt.Errorf("reality requires public_key")
	}
	publicKey, err := parseRealityPublicKey(reality.PublicKey)
	if err != nil {
		return nil, err
	}
	shortID, err := parseRealityShortID(reality.ShortID)
	if err != nil {
		return nil, err
	}
	helloID, err := clientHelloIDFromString(opts.UTLSFingerprint)
	if err != nil {
		return nil, err
	}
	if helloID == utls.HelloGolang {
		return nil, fmt.Errorf("reality requires a non-Golang uTLS fingerprint")
	}

	raw, err := dialRawTCP(ctx, host, port)
	if err != nil {
		return nil, err
	}

	var authKey []byte
	verified := false
	cfg := &utls.Config{
		ServerName:             opts.ServerName,
		InsecureSkipVerify:     true,
		SessionTicketsDisabled: true,
		NextProtos:             nextProtos,
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			if len(rawCerts) == 0 {
				return fmt.Errorf("reality: no server certificate")
			}
			if authKey == nil {
				return fmt.Errorf("reality: auth key is not initialized")
			}
			cert, err := x509.ParseCertificate(rawCerts[0])
			if err != nil {
				return fmt.Errorf("reality: parse server certificate: %w", err)
			}
			pub, ok := cert.PublicKey.(ed25519.PublicKey)
			if !ok {
				return fmt.Errorf("reality: server certificate is not ed25519")
			}
			mac := hmac.New(sha512.New, authKey)
			_, _ = mac.Write(pub)
			if !hmac.Equal(mac.Sum(nil), cert.Signature) {
				return fmt.Errorf("reality: server certificate did not authenticate")
			}
			verified = true
			return nil
		},
	}

	conn := utls.UClient(raw, cfg, helloID)
	if err := conn.BuildHandshakeState(); err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: build client hello: %w", err)
	}

	hello := conn.HandshakeState.Hello
	if hello == nil || len(hello.Random) != 32 {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: invalid client hello random")
	}
	if len(hello.SessionId) != 32 {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: fingerprint session id must be 32 bytes, got %d", len(hello.SessionId))
	}
	keys := conn.HandshakeState.State13.KeyShareKeys
	if keys == nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: missing TLS 1.3 key-share state")
	}
	ecdhKey := keys.Ecdhe
	if ecdhKey == nil {
		ecdhKey = keys.MlkemEcdhe
	}
	if ecdhKey == nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: missing X25519 ECDHE key")
	}

	shared, err := ecdhKey.ECDH(publicKey)
	if err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: derive shared secret: %w", err)
	}
	authKey, err = hkdf.Key(sha256.New, shared, hello.Random[:20], "REALITY", 32)
	if err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: derive auth key: %w", err)
	}

	// Keep a copy of the original raw ClientHello. REALITY uses the original
	// message as AEAD additional data, then replaces the session-id bytes.
	originalHello := append([]byte(nil), hello.Raw...)
	if len(originalHello) < realitySessionIDOffset+32 {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: client hello is too short (%d bytes)", len(originalHello))
	}

	sessionID := make([]byte, 32)
	sessionID[0] = realityClientVersionMajor
	sessionID[1] = realityClientVersionMinor
	sessionID[2] = realityClientVersionPatch
	binary.BigEndian.PutUint32(sessionID[4:8], uint32(time.Now().Unix()))
	copy(sessionID[8:16], shortID[:])

	block, err := aes.NewCipher(authKey)
	if err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: create aes cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: create aes-gcm: %w", err)
	}
	cipherSessionID := aead.Seal(nil, hello.Random[20:32], sessionID[:16], originalHello)
	if len(cipherSessionID) != 32 {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: unexpected sealed session-id length %d", len(cipherSessionID))
	}

	// HandshakeContext will call BuildHandshakeState again and marshal the
	// current Hello.SessionId, so this is enough to send the encrypted value.
	hello.SessionId = make([]byte, 32)
	copy(hello.SessionId, cipherSessionID)
	copy(originalHello[realitySessionIDOffset:realitySessionIDOffset+32], cipherSessionID)
	hello.Raw = originalHello

	if err := conn.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("reality: handshake: %w", err)
	}
	if !verified {
		_ = conn.Close()
		return nil, fmt.Errorf("reality: server was not authenticated")
	}
	return conn, nil
}

func parseRealityPublicKey(s string) (*ecdh.PublicKey, error) {
	raw, err := decodeBase64Flexible(s)
	if err != nil {
		return nil, fmt.Errorf("reality: decode public_key: %w", err)
	}
	if len(raw) != 32 {
		return nil, fmt.Errorf("reality: public_key must decode to 32 bytes, got %d", len(raw))
	}
	pub, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, fmt.Errorf("reality: invalid X25519 public_key: %w", err)
	}
	return pub, nil
}

func parseRealityShortID(s string) ([8]byte, error) {
	var out [8]byte
	s = strings.TrimSpace(s)
	if s == "" {
		return out, nil
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return out, fmt.Errorf("reality: decode short_id: %w", err)
	}
	if len(b) > 8 {
		return out, fmt.Errorf("reality: short_id must be at most 8 bytes")
	}
	copy(out[:], b)
	return out, nil
}

func decodeBase64Flexible(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	encodings := []*base64.Encoding{
		base64.RawURLEncoding,
		base64.RawStdEncoding,
		base64.URLEncoding,
		base64.StdEncoding,
	}
	for _, enc := range encodings {
		if b, err := enc.DecodeString(s); err == nil {
			return b, nil
		}
	}
	return nil, fmt.Errorf("invalid base64")
}

func isPlainTLSFingerprint(s string) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "", "none", "golang", "default", "disabled":
		return true
	default:
		return false
	}
}

func clientHelloIDFromString(s string) (utls.ClientHelloID, error) {
	v := strings.ToLower(strings.ReplaceAll(strings.TrimSpace(s), "-", "_"))
	switch v {
	case "chrome", "chrome_auto", "auto":
		return utls.HelloChrome_Auto, nil
	case "firefox", "firefox_auto":
		return utls.HelloFirefox_Auto, nil
	case "safari", "safari_auto":
		return utls.HelloSafari_Auto, nil
	case "ios", "ios_auto":
		return utls.HelloIOS_Auto, nil
	case "edge", "edge_auto":
		return utls.HelloEdge_Auto, nil
	case "android", "android_11_okhttp", "okhttp":
		return utls.HelloAndroid_11_OkHttp, nil
	case "randomized", "random":
		return utls.HelloRandomized, nil
	case "chrome_58":
		return utls.HelloChrome_58, nil
	case "chrome_62":
		return utls.HelloChrome_62, nil
	case "chrome_70":
		return utls.HelloChrome_70, nil
	case "chrome_72":
		return utls.HelloChrome_72, nil
	case "chrome_83":
		return utls.HelloChrome_83, nil
	case "chrome_87":
		return utls.HelloChrome_87, nil
	case "chrome_96":
		return utls.HelloChrome_96, nil
	case "chrome_100":
		return utls.HelloChrome_100, nil
	case "chrome_102":
		return utls.HelloChrome_102, nil
	case "chrome_120":
		return utls.HelloChrome_120, nil
	case "chrome_131":
		return utls.HelloChrome_131, nil
	case "chrome_133":
		return utls.HelloChrome_133, nil
	case "firefox_55":
		return utls.HelloFirefox_55, nil
	case "firefox_56":
		return utls.HelloFirefox_56, nil
	case "firefox_63":
		return utls.HelloFirefox_63, nil
	case "firefox_65":
		return utls.HelloFirefox_65, nil
	case "firefox_99":
		return utls.HelloFirefox_99, nil
	case "firefox_102":
		return utls.HelloFirefox_102, nil
	case "firefox_105":
		return utls.HelloFirefox_105, nil
	case "firefox_120":
		return utls.HelloFirefox_120, nil
	case "edge_85":
		return utls.HelloEdge_85, nil
	case "edge_106":
		return utls.HelloEdge_106, nil
	case "safari_16_0":
		return utls.HelloSafari_16_0, nil
	case "ios_14":
		return utls.HelloIOS_14, nil
	default:
		return utls.ClientHelloID{}, fmt.Errorf("unsupported uTLS fingerprint %q", s)
	}
}
