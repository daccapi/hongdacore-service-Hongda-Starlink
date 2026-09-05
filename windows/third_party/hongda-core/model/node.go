package model

// ProtocolType is Hongda's unified protocol identifier. Importers and the
// runtime use this type; no upstream config format leaks into the model.
type ProtocolType string

const (
	ProtocolDirect      ProtocolType = "direct"
	ProtocolVLESS       ProtocolType = "vless"
	ProtocolTrojan      ProtocolType = "trojan"
	ProtocolVMess       ProtocolType = "vmess"
	ProtocolShadowsocks ProtocolType = "shadowsocks"
	ProtocolHysteria2   ProtocolType = "hysteria2"
	ProtocolTUIC        ProtocolType = "tuic"
	ProtocolWireGuard   ProtocolType = "wireguard"
	ProtocolTailscale   ProtocolType = "tailscale"
)

type TLSOptions struct {
	Enabled         bool
	ServerName      string
	Insecure        bool
	UTLSFingerprint string
	Reality         *RealityOptions
}

type RealityOptions struct {
	Enabled   bool
	PublicKey string
	ShortID   string
}

type TransportOptions struct {
	Type        string // raw | ws | grpc | http
	Path        string
	Host        string
	ServiceName string
}

type DialOptions struct {
	BindInterface  string
	DomainResolver string
}

// Node is the unified node model. Protocol adapters must consume this struct
// rather than external JSON/YAML formats.
type Node struct {
	ID        string
	Name      string
	Type      ProtocolType
	Server    string
	Port      uint16
	TLS       *TLSOptions
	Transport *TransportOptions
	Auth      map[string]string
	Dial      DialOptions
	UDP       bool
	Tags      map[string]string
}
