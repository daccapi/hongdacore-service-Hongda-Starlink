//go:build windows && with_gvisor

package tunnel

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	"github.com/sagernet/sing/common/logger"

	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/route"
)

type windowsManager struct {
	inbound model.InboundConfig
	config  *model.Config
	router  *route.Router

	ctx              context.Context
	cancel           context.CancelFunc
	device           tun.Tun
	stack            tun.Stack
	networkMonitor   tun.NetworkUpdateMonitor
	interfaceMonitor tun.DefaultInterfaceMonitor
	routeCleanup     []netip.Prefix
	interfaceIndex   int
	closeOnce        sync.Once
}

func Supported() bool { return true }

func New(inbound model.InboundConfig, router *route.Router, config *model.Config) (Manager, error) {
	if router == nil || config == nil {
		return nil, fmt.Errorf("TUN requires a built router and config")
	}
	if config.DNS.Mode != "doh" || strings.TrimSpace(config.DNS.Server) == "" {
		return nil, fmt.Errorf("TUN requires encrypted DNS (dns.mode=doh)")
	}
	return &windowsManager{inbound: inbound, router: router, config: config}, nil
}

func (m *windowsManager) Start() error {
	m.ctx, m.cancel = context.WithCancel(context.Background())
	log := logger.NOP()
	finder := control.NewDefaultInterfaceFinder()
	if err := finder.Update(); err != nil {
		return fmt.Errorf("enumerate network interfaces: %w", err)
	}

	networkMonitor, err := tun.NewNetworkUpdateMonitor(log)
	if err != nil {
		return fmt.Errorf("create network monitor: %w", err)
	}
	m.networkMonitor = networkMonitor
	if err := m.networkMonitor.Start(); err != nil {
		_ = m.Close()
		return fmt.Errorf("start network monitor: %w", err)
	}
	interfaceMonitor, err := tun.NewDefaultInterfaceMonitor(networkMonitor, log, tun.DefaultInterfaceMonitorOptions{InterfaceFinder: finder})
	if err != nil {
		_ = m.Close()
		return fmt.Errorf("create default-interface monitor: %w", err)
	}
	m.interfaceMonitor = interfaceMonitor
	if err := m.interfaceMonitor.Start(); err != nil {
		_ = m.Close()
		return fmt.Errorf("start default-interface monitor: %w", err)
	}
	if m.inbound.TUNAutoRoute {
		physical := m.interfaceMonitor.DefaultInterface()
		if physical == nil || physical.Index <= 0 {
			_ = m.Close()
			return fmt.Errorf("no physical default interface found before enabling auto-route")
		}
		m.router.SetDirectInterface(physical.Index)
		m.interfaceMonitor.RegisterCallback(func(updated *control.Interface, _ int) {
			if updated != nil && updated.Index > 0 {
				m.router.SetDirectInterface(updated.Index)
			}
		})
	}

	options, err := m.options(finder)
	if err != nil {
		_ = m.Close()
		return err
	}
	tun.TunnelType = "HongdaCore"
	device, err := tun.New(options)
	if err != nil {
		_ = m.Close()
		return fmt.Errorf("create Wintun interface (run as administrator): %w", err)
	}
	m.device = device
	if name, nameErr := device.Name(); nameErr == nil {
		m.interfaceMonitor.RegisterMyInterface(name)
	}
	if options.AutoRoute {
		m.routeCleanup, err = options.BuildAutoRouteRanges(false)
		if err != nil {
			_ = m.Close()
			return fmt.Errorf("calculate TUN route rollback set: %w", err)
		}
		if name, nameErr := device.Name(); nameErr == nil {
			if networkInterface, interfaceErr := net.InterfaceByName(name); interfaceErr == nil {
				m.interfaceIndex = networkInterface.Index
			}
		}
	}

	stackName := strings.ToLower(strings.TrimSpace(m.inbound.TUNStack))
	if stackName == "" || stackName == "mixed" || stackName == "system" {
		// The clean core always uses userspace gVisor. The system stack cannot
		// deliver intercepted TCP/UDP sessions to Hongda's outbound router.
		stackName = "gvisor"
	}
	stack, err := tun.NewStack(stackName, tun.StackOptions{
		Context:         m.ctx,
		Tun:             device,
		TunOptions:      options,
		UDPTimeout:      5 * time.Minute,
		ICMPTimeout:     30 * time.Second,
		UDPNATMax:       1024,
		Handler:         &handler{router: m.router},
		Logger:          log,
		InterfaceFinder: finder,
	})
	if err != nil {
		_ = m.Close()
		return fmt.Errorf("create gVisor stack: %w", err)
	}
	m.stack = stack
	if err := m.stack.Start(); err != nil {
		_ = m.Close()
		return fmt.Errorf("start gVisor stack: %w", err)
	}
	if err := m.device.Start(); err != nil {
		_ = m.Close()
		return fmt.Errorf("install TUN routes: %w", err)
	}
	return nil
}

func (m *windowsManager) options(finder control.InterfaceFinder) (tun.Options, error) {
	name := strings.TrimSpace(m.inbound.TUNInterface)
	if name == "" {
		name = "HongdaTun"
	}
	addresses := m.inbound.TUNAddress
	if len(addresses) == 0 {
		addresses = []string{"172.19.0.1/30"}
	}
	var inet4, inet6 []netip.Prefix
	for _, raw := range addresses {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil {
			return tun.Options{}, fmt.Errorf("invalid TUN address %q: %w", raw, err)
		}
		if prefix.Addr().Is4() {
			inet4 = append(inet4, prefix)
		} else {
			inet6 = append(inet6, prefix)
		}
	}
	var route4, route6 []netip.Prefix
	for _, raw := range m.inbound.TUNRouteAddr {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil {
			return tun.Options{}, fmt.Errorf("invalid TUN route %q: %w", raw, err)
		}
		if prefix.Addr().Is4() {
			route4 = append(route4, prefix)
		} else {
			route6 = append(route6, prefix)
		}
	}
	exclude4, exclude6, err := m.endpointExclusions()
	if err != nil {
		return tun.Options{}, err
	}
	mtu := m.inbound.TUNMTU
	if mtu <= 0 {
		mtu = 1500
	}
	return tun.Options{
		Name:                     name,
		Inet4Address:             inet4,
		Inet6Address:             inet6,
		MTU:                      uint32(mtu),
		AutoRoute:                m.inbound.TUNAutoRoute,
		StrictRoute:              m.inbound.TUNStrictRoute,
		DNSMode:                  tun.DNSModeHijack,
		Inet4RouteAddress:        route4,
		Inet6RouteAddress:        route6,
		Inet4RouteExcludeAddress: exclude4,
		Inet6RouteExcludeAddress: exclude6,
		InterfaceFinder:          finder,
		InterfaceMonitor:         m.interfaceMonitor,
		Logger:                   logger.NOP(),
		EXP_MultiPendingPackets:  true,
	}, nil
}

func (m *windowsManager) endpointExclusions() (v4, v6 []netip.Prefix, resultErr error) {
	seen := make(map[netip.Addr]bool)
	addHost := func(host string) error {
		host = strings.TrimSpace(strings.Trim(host, "[]"))
		if host == "" {
			return fmt.Errorf("empty upstream host")
		}
		if addr, err := netip.ParseAddr(host); err == nil {
			seen[addr.Unmap()] = true
			return nil
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		addrs, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		if err != nil {
			return fmt.Errorf("resolve upstream %q before installing TUN routes: %w", host, err)
		}
		if len(addrs) == 0 {
			return fmt.Errorf("upstream %q resolved to no addresses", host)
		}
		for _, addr := range addrs {
			seen[addr.Unmap()] = true
		}
		return nil
	}
	for _, node := range m.config.Nodes {
		if err := addHost(node.Server); err != nil {
			return nil, nil, err
		}
	}
	if m.config.DNS.Detour == "" || m.config.DNS.Detour == "direct" {
		if u, err := url.Parse(m.config.DNS.Server); err == nil {
			if err := addHost(u.Hostname()); err != nil {
				return nil, nil, err
			}
		}
	}
	for addr := range seen {
		bits := 128
		if addr.Is4() {
			bits = 32
			v4 = append(v4, netip.PrefixFrom(addr, bits))
		} else {
			v6 = append(v6, netip.PrefixFrom(addr, bits))
		}
	}
	return v4, v6, nil
}

func (m *windowsManager) Close() error {
	var closeErr error
	m.closeOnce.Do(func() {
		if m.cancel != nil {
			m.cancel()
		}
		// Removing routes first is deliberate: even if stack shutdown stalls,
		// applications immediately regain the physical default route.
		if err := m.removeRoutes(); err != nil {
			closeErr = err
		}
		if m.device != nil {
			if err := m.device.Close(); err != nil {
				if closeErr == nil {
					closeErr = err
				}
			}
		}
		if m.stack != nil {
			_ = m.stack.Close()
		}
		if m.interfaceMonitor != nil {
			_ = m.interfaceMonitor.Close()
		}
		if m.networkMonitor != nil {
			_ = m.networkMonitor.Close()
		}
	})
	return closeErr
}

func (m *windowsManager) removeRoutes() error {
	if m.interfaceIndex <= 0 || len(m.routeCleanup) == 0 {
		return nil
	}
	var firstErr error
	for _, prefix := range m.routeCleanup {
		family := "ipv6"
		if prefix.Addr().Is4() {
			family = "ipv4"
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		command := exec.CommandContext(ctx, "netsh", "interface", family, "delete", "route",
			"prefix="+prefix.String(), "interface="+strconv.Itoa(m.interfaceIndex), "store=active")
		if output, err := command.CombinedOutput(); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("remove stale TUN route %s: %w (%s)", prefix, err, strings.TrimSpace(string(output)))
		}
		cancel()
	}
	return firstErr
}
