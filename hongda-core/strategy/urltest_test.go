package strategy

import (
	"errors"
	"testing"
	"time"
)

func TestURLTestToleranceKeepsHealthyCurrent(t *testing.T) {
	selected, ready := chooseURLTestCurrent("current", 50*time.Millisecond, []urlTestResult{
		{name: "faster", latency: 80 * time.Millisecond},
		{name: "current", latency: 115 * time.Millisecond},
	})
	if !ready || selected != "current" {
		t.Fatalf("selected=%q ready=%v, want healthy current", selected, ready)
	}
}

func TestURLTestSwitchesForMaterialImprovement(t *testing.T) {
	selected, ready := chooseURLTestCurrent("current", 25*time.Millisecond, []urlTestResult{
		{name: "faster", latency: 40 * time.Millisecond},
		{name: "current", latency: 100 * time.Millisecond},
	})
	if !ready || selected != "faster" {
		t.Fatalf("selected=%q ready=%v, want faster", selected, ready)
	}
}

func TestURLTestFailsOverWhenCurrentFails(t *testing.T) {
	selected, ready := chooseURLTestCurrent("current", 500*time.Millisecond, []urlTestResult{
		{name: "backup", latency: 90 * time.Millisecond},
		{name: "current", err: errors.New("unreachable")},
	})
	if !ready || selected != "backup" {
		t.Fatalf("selected=%q ready=%v, want backup", selected, ready)
	}
}

func TestURLTestKeepsLastSelectionWhenAllFail(t *testing.T) {
	selected, ready := chooseURLTestCurrent("current", 50*time.Millisecond, []urlTestResult{
		{name: "current", err: errors.New("unreachable")},
		{name: "backup", err: errors.New("unreachable")},
	})
	if ready || selected != "current" {
		t.Fatalf("selected=%q ready=%v, want unhealthy current", selected, ready)
	}
}
