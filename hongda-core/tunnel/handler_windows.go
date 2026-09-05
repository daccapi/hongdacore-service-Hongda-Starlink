//go:build windows && with_gvisor

package tunnel

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"

	"hongda.local/hongda-core/route"
)

type handler struct {
	router *route.Router
}

func (h *handler) JudgeFlow(network uint8, _ netip.AddrPort, destination netip.AddrPort, _ []byte) tun.FlowVerdict {
	if network == 17 && destination.Port() == 53 { // UDP
		return tun.FlowVerdict{Action: tun.ActionHijackDNS}
	}
	return tun.FlowVerdict{Action: tun.ActionAccept}
}

func (h *handler) NewDNSPacket(payload []byte, _ M.Socksaddr, destination M.Socksaddr, writer N.PacketWriter) {
	query := append([]byte(nil), payload...)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
		defer cancel()
		response, err := h.router.ExchangeDNS(ctx, query)
		if err != nil {
			return
		}
		h.router.AddUpload(int64(len(query)))
		h.router.AddDownload(int64(len(response)))
		_ = writer.WritePacket(buf.As(response), destination)
	}()
}

func (h *handler) NewConnectionEx(ctx context.Context, conn net.Conn, _ M.Socksaddr, destination M.Socksaddr, onClose N.CloseHandlerFunc) {
	upstream, err := h.router.Dial("tcp", destination.String())
	if err != nil {
		_ = conn.Close()
		if onClose != nil {
			onClose(err)
		}
		return
	}
	h.router.PipeTarget(conn, upstream, destination.String())
	if onClose != nil {
		onClose(nil)
	}
}

func (h *handler) NewPacketConnectionEx(ctx context.Context, conn N.PacketConn, _ M.Socksaddr, firstDestination M.Socksaddr, onClose N.CloseHandlerFunc) {
	type udpPeer struct {
		conn        net.Conn
		destination M.Socksaddr
	}
	var (
		mu      sync.Mutex
		peers   = make(map[string]*udpPeer)
		closing sync.Once
	)
	closeAll := func() {
		closing.Do(func() {
			_ = conn.Close()
			mu.Lock()
			for _, peer := range peers {
				_ = peer.conn.Close()
			}
			mu.Unlock()
		})
	}
	tracked := h.router.TrackConnection("udp", firstDestination.String(), closeAll)
	defer func() {
		closeAll()
		h.router.UntrackConnection(tracked)
		if onClose != nil {
			onClose(nil)
		}
	}()

	getPeer := func(destination M.Socksaddr) (*udpPeer, error) {
		key := destination.String()
		mu.Lock()
		peer := peers[key]
		mu.Unlock()
		if peer != nil {
			return peer, nil
		}
		upstream, err := h.router.Dial("udp", key)
		if err != nil {
			return nil, err
		}
		peer = &udpPeer{conn: upstream, destination: destination}
		mu.Lock()
		if existing := peers[key]; existing != nil {
			mu.Unlock()
			_ = upstream.Close()
			return existing, nil
		}
		peers[key] = peer
		mu.Unlock()
		go func() {
			packet := make([]byte, 64*1024)
			for {
				n, readErr := peer.conn.Read(packet)
				if n > 0 {
					response := append([]byte(nil), packet[:n]...)
					if writeErr := conn.WritePacket(buf.As(response), peer.destination); writeErr != nil {
						closeAll()
						return
					}
					h.router.AddDownload(int64(n))
					tracked.Download.Add(int64(n))
				}
				if readErr != nil {
					if !errors.Is(readErr, net.ErrClosed) && !errors.Is(readErr, io.EOF) {
						closeAll()
					}
					return
				}
			}
		}()
		return peer, nil
	}

	for {
		packet := buf.NewPacket()
		destination, err := conn.ReadPacket(packet)
		if err != nil {
			packet.Release()
			return
		}
		peer, err := getPeer(destination)
		if err != nil {
			packet.Release()
			return
		}
		payload := packet.Bytes()
		n, err := peer.conn.Write(payload)
		packet.Release()
		if n > 0 {
			h.router.AddUpload(int64(n))
			tracked.Upload.Add(int64(n))
		}
		if err != nil {
			return
		}
		select {
		case <-ctx.Done():
			return
		default:
		}
	}
}
