//go:build windows && with_gvisor

package tunnel

import (
	tun "github.com/sagernet/sing-tun"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
	"hongda.local/hongda-core/telemetry"
	"net/netip"
	"testing"
)

func TestRejectedQUICReturnsStackReject(t *testing.T) {
	r := route.New("proxy", &telemetry.Traffic{}, telemetry.NewConnections())
	defer r.Close()
	r.SetPolicy([]model.Rule{
		{Match: model.MatchExpr{IPCIDR: []string{"private"}}, Action: model.ActionRoute, Target: "direct"},
		{Match: model.MatchExpr{Network: "udp", Port: []string{"443"}}, Action: model.ActionReject},
	}, model.DNSOptions{})
	h := handler{router: r}
	for _, tc := range []struct {
		name, address string
		proto         uint8
		want          tun.FlowVerdict
	}{
		{"QUIC sends unreachable", "203.0.113.1:443", 17, tun.FlowVerdict{Action: tun.ActionReject}},
		{"DNS interception", "172.19.0.2:53", 17, tun.FlowVerdict{Action: tun.ActionHijackDNS}},
		{"LAN policy retained", "192.168.0.1:443", 17, tun.FlowVerdict{Action: tun.ActionAccept}},
		{"TCP fallback allowed", "203.0.113.1:443", 6, tun.FlowVerdict{Action: tun.ActionAccept}},
		{"Other UDP allowed", "203.0.113.1:123", 17, tun.FlowVerdict{Action: tun.ActionAccept}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := h.JudgeFlow(tc.proto, netip.AddrPort{}, netip.MustParseAddrPort(tc.address), nil)
			if got.Action != tc.want.Action {
				t.Fatalf("action=%v want %v", got.Action, tc.want.Action)
			}
		})
	}
}
