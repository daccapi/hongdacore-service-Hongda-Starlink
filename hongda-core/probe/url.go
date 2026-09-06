// Package probe shares bounded, end-to-end health checks between the API and
// automatic selection. Queue time is not reported as node latency.
package probe

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"sync/atomic"
	"time"

	"hongda.local/hongda-core/model"
)

const Concurrency = 4

var slots = make(chan struct{}, Concurrency)

type Result struct {
	Total   time.Duration
	Connect time.Duration
	Status  int
}

func Measure(ctx context.Context, ob model.Outbound, target string) (Result, error) {
	select {
	case slots <- struct{}{}:
	case <-ctx.Done():
		return Result{}, ctx.Err()
	}
	defer func() { <-slots }()
	if err := ctx.Err(); err != nil {
		return Result{}, err
	}
	var connectNanos atomic.Int64
	transport := &http.Transport{
		Proxy: nil, DisableKeepAlives: true,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			start := time.Now()
			conn, err := ob.DialContext(ctx, network, address)
			connectNanos.Store(int64(time.Since(start)))
			return conn, err
		},
	}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, target, nil)
	if err != nil {
		return Result{}, err
	}
	request.Header.Set("User-Agent", "HongdaCore-URLTest")
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return Result{}, err
	}
	defer response.Body.Close()
	result := Result{Total: time.Since(start), Connect: time.Duration(connectNanos.Load()), Status: response.StatusCode}
	if result.Connect <= 0 || result.Connect > result.Total {
		result.Connect = result.Total
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return result, fmt.Errorf("URL test HTTP status %d", response.StatusCode)
	}
	return result, nil
}
