package ruleset

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"hongda.local/hongda-core/model"
)

func TestLoadRewritesBinaryURLAndUsesFreshCache(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.URL.Path != "/sample.json" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"version":3,"rules":[{"domain_suffix":["example.com"]}]}`))
	}))
	defer server.Close()
	config := model.RulesetConfig{
		ID: "sample", URL: server.URL + "/sample.srs", Format: "binary", UpdateInterval: 3600,
	}
	cacheDir := t.TempDir()
	first, err := Load(context.Background(), config, cacheDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	second, err := Load(context.Background(), config, cacheDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !first.MatchDomain("www.example.com") || !second.MatchDomain("www.example.com") {
		t.Fatal("cached set did not match")
	}
	if requests.Load() != 1 {
		t.Fatalf("requests = %d, want 1", requests.Load())
	}
}

func TestLoadFallsBackToValidStaleCache(t *testing.T) {
	config := model.RulesetConfig{
		ID: "stale", URL: "http://127.0.0.1:1/stale.json", Format: "source", UpdateInterval: 1,
	}
	cacheDir := t.TempDir()
	cachePath := filepath.Join(cacheDir, cacheName(config))
	data := []byte(`{"version":3,"rules":[{"domain":["cached.example"]}]}`)
	if err := os.WriteFile(cachePath, data, 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(cachePath, old, old); err != nil {
		t.Fatal(err)
	}
	set, err := Load(context.Background(), config, cacheDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !set.MatchDomain("cached.example") {
		t.Fatal("stale cache fallback did not match")
	}
}

func TestLoadAtomicallyReplacesStaleCache(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"version":3,"rules":[{"domain":["new.example"]}]}`))
	}))
	defer server.Close()
	config := model.RulesetConfig{
		ID: "replace", URL: server.URL + "/replace.json", Format: "source", UpdateInterval: 1,
	}
	cacheDir := t.TempDir()
	cachePath := filepath.Join(cacheDir, cacheName(config))
	oldData := []byte(`{"version":3,"rules":[{"domain":["old.example"]}]}`)
	if err := os.WriteFile(cachePath, oldData, 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(cachePath, old, old); err != nil {
		t.Fatal(err)
	}
	set, err := Load(context.Background(), config, cacheDir, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !set.MatchDomain("new.example") || set.MatchDomain("old.example") {
		t.Fatal("stale cache was not replaced")
	}
	cached, err := os.ReadFile(cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(cached) == string(oldData) {
		t.Fatal("cache file still contains old data")
	}
}

func TestLoadRetriesTransientDownloadFailure(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			http.Error(w, "temporary", http.StatusServiceUnavailable)
			return
		}
		_, _ = w.Write([]byte(`{"version":3,"rules":[{"domain_suffix":["retry.example"]}]}`))
	}))
	defer server.Close()
	config := model.RulesetConfig{ID: "retry", URL: server.URL + "/retry.json", Format: "source"}
	set, err := Load(context.Background(), config, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !set.MatchDomain("www.retry.example") || requests.Load() != 2 {
		t.Fatalf("retry result match=%v requests=%d", set.MatchDomain("www.retry.example"), requests.Load())
	}
}

func TestLoadUsesFallbackSource(t *testing.T) {
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"unexpected":"cdn error page"}`))
	}))
	defer primary.Close()
	fallback := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/fallback.json" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte(`{"version":3,"rules":[{"domain_suffix":["fallback.example"]}]}`))
	}))
	defer fallback.Close()
	config := model.RulesetConfig{
		ID: "fallback", URL: primary.URL + "/primary.srs", Format: "binary",
		FallbackURLs: []string{fallback.URL + "/fallback.srs"},
	}
	set, err := Load(context.Background(), config, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if !set.MatchDomain("www.fallback.example") {
		t.Fatal("fallback source did not load")
	}
}

func TestOptionalRuleSetStartsEmptyWithoutNetwork(t *testing.T) {
	config := model.RulesetConfig{
		ID: "optional", URL: "http://127.0.0.1:1/missing.json", Format: "source", Optional: true,
	}
	set, err := Load(context.Background(), config, t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if set.ID() != "optional" || set.MatchDomain("example.com") {
		t.Fatal("optional offline rule set should be empty")
	}
}
