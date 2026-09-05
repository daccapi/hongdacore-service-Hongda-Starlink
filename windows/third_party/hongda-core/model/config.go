package model

// Config is Hongda's native runtime config. Clash YAML and sing-box JSON are
// import-only formats and are compiled into this model.
type Config struct {
	Log       LogOptions       `json:"log"`
	Core      CoreOptions      `json:"core"`
	DNS       DNSOptions       `json:"dns"`
	Inbounds  []InboundConfig  `json:"inbounds"`
	Nodes     []Node           `json:"nodes"`
	Groups    []GroupConfig    `json:"groups"`
	Providers []ProviderConfig `json:"providers"`
	Rulesets  []RulesetConfig  `json:"rulesets"`
	Rules     []Rule           `json:"rules"`
	Route     RouteConfig      `json:"route"`
	API       APIConfig        `json:"api"`
}

type LogOptions struct {
	Level     string `json:"level"`
	Timestamp bool   `json:"timestamp"`
}

type CoreOptions struct {
	TUN      bool   `json:"tun"`
	IPv6     bool   `json:"ipv6"`
	CacheDir string `json:"cache_dir,omitempty"`
}

type DNSOptions struct {
	Mode      string `json:"mode"`
	Server    string `json:"server"`
	TLSServer string `json:"tls_server_name,omitempty"`
	Detour    string `json:"detour,omitempty"`
	Strategy  string `json:"strategy,omitempty"`
	FakeIP    string `json:"fake_ip"`
}

// InboundConfig is the compiled representation of a traffic entry point.
// TUN-specific fields are kept inline so the runtime can decide whether to
// bring up a system interface without a second import pass.
type InboundConfig struct {
	Type           string   `json:"type"` // mixed | tun
	Tag            string   `json:"tag"`
	Listen         string   `json:"listen"`
	Port           uint16   `json:"port"`
	TUNAddress     []string `json:"tun_address,omitempty"`
	TUNMTU         int      `json:"tun_mtu,omitempty"`
	TUNAutoRoute   bool     `json:"tun_auto_route,omitempty"`
	TUNStrictRoute bool     `json:"tun_strict_route,omitempty"`
	TUNStack       string   `json:"tun_stack,omitempty"`
	TUNInterface   string   `json:"tun_interface,omitempty"`
	TUNRouteAddr   []string `json:"tun_route_address,omitempty"`
}

type GroupConfig struct {
	ID        string   `json:"id"`
	Type      string   `json:"type"` // select | urltest | fallback | balance
	Members   []string `json:"members"`
	URL       string   `json:"url"`
	Interval  int      `json:"interval"`
	Tolerance int      `json:"tolerance"`
	Default   string   `json:"default,omitempty"`
}

type ProviderConfig struct {
	ID  string `json:"id"`
	URL string `json:"url"`
}

type RulesetConfig struct {
	ID             string `json:"id"`
	Type           string `json:"type,omitempty"`
	Format         string `json:"format,omitempty"`
	URL            string `json:"url"`
	DownloadDetour string `json:"download_detour,omitempty"`
	UpdateInterval int    `json:"update_interval,omitempty"`
}

type RouteConfig struct {
	Final string `json:"final"`
}

type APIConfig struct {
	Listen string `json:"listen"`
	Secret string `json:"secret"`
}
