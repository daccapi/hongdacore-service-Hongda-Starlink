package telemetry

import (
	"sync/atomic"
	"testing"
)

func TestCloseAllClosesRealConnection(t *testing.T) {
	connections := NewConnections()
	var calls atomic.Int32
	connection := connections.Add("tcp", "example.com", "example.com:443", func() {
		calls.Add(1)
	})
	connections.CloseAll()
	connections.CloseAll()
	if calls.Load() != 1 {
		t.Fatalf("close calls = %d", calls.Load())
	}
	connections.Remove(connection.ID)
	if connection.ClosedAt().IsZero() {
		t.Fatal("closed timestamp was not recorded")
	}
}
