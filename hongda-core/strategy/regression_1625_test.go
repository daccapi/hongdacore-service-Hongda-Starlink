package strategy

import (
	"context"
	"hongda.local/hongda-core/model"
	"hongda.local/hongda-core/protocol"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestRegressionURLTestRejectsHTTP503(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "proxy unavailable", 503) }))
	defer server.Close()
	group := NewURLTest("auto", map[string]model.Outbound{"node": protocol.NewDirect("node")}, server.URL, 0)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	err := group.Refresh(ctx)
	if err == nil && group.Health().Ready {
		t.Fatal("URLTest marks HTTP 503 response healthy and selectable")
	}
}
