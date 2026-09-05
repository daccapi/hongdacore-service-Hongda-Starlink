package ruleset

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"hongda.local/hongda-core/model"
)

const maxSourceSize = 32 << 20

const (
	downloadAttempts = 2
	downloadTimeout  = 60 * time.Second
)

type DialContext func(context.Context, string, string) (net.Conn, error)

func Load(ctx context.Context, config model.RulesetConfig, cacheDir string, dialContext DialContext) (*Set, error) {
	if config.ID == "" || config.URL == "" {
		return nil, fmt.Errorf("remote rule set requires id and url")
	}
	if cacheDir == "" {
		return nil, fmt.Errorf("rule set %q: cache directory is empty", config.ID)
	}
	if err := os.MkdirAll(cacheDir, 0o700); err != nil {
		return nil, fmt.Errorf("create rule-set cache: %w", err)
	}
	cachePath := filepath.Join(cacheDir, cacheName(config))
	cachedData, cachedInfo, cachedErr := readCache(cachePath)
	var cachedSet *Set
	if cachedErr == nil {
		cachedSet, cachedErr = ParseSource(config.ID, cachedData)
	}
	interval := time.Duration(config.UpdateInterval) * time.Second
	if interval <= 0 {
		interval = 24 * time.Hour
	}
	if cachedErr == nil && time.Since(cachedInfo.ModTime()) < interval {
		return cachedSet, nil
	}

	var (
		data        []byte
		set         *Set
		downloadErr error
	)
	for _, source := range sourceURLs(config) {
		data, downloadErr = download(ctx, source, dialContext)
		if downloadErr != nil {
			downloadErr = fmt.Errorf("%s: %w", source, downloadErr)
			continue
		}
		set, downloadErr = ParseSource(config.ID, data)
		if downloadErr == nil {
			break
		}
		downloadErr = fmt.Errorf("%s: %w", source, downloadErr)
	}
	if set == nil {
		if cachedSet != nil {
			return cachedSet, nil
		}
		if config.Optional {
			return NewEmpty(config.ID), nil
		}
		return nil, fmt.Errorf("download rule set %q: %w", config.ID, downloadErr)
	}
	if err := writeCacheAtomic(cachePath, data); err != nil {
		return nil, fmt.Errorf("cache rule set %q: %w", config.ID, err)
	}
	return set, nil
}

func sourceURLs(config model.RulesetConfig) []string {
	values := make([]string, 0, 1+len(config.FallbackURLs))
	seen := make(map[string]bool)
	for _, raw := range append([]string{config.URL}, config.FallbackURLs...) {
		source := rewriteSourceURL(config, strings.TrimSpace(raw))
		if source != "" && !seen[source] {
			seen[source] = true
			values = append(values, source)
		}
	}
	return values
}

func rewriteSourceURL(config model.RulesetConfig, source string) string {
	if config.Format != "binary" {
		return source
	}
	parsed, err := url.Parse(source)
	if err != nil {
		return source
	}
	if strings.EqualFold(filepath.Ext(parsed.Path), ".srs") {
		parsed.Path = strings.TrimSuffix(parsed.Path, filepath.Ext(parsed.Path)) + ".json"
	}
	return parsed.String()
}

func download(ctx context.Context, source string, dialContext DialContext) ([]byte, error) {
	var lastErr error
	for attempt := 1; attempt <= downloadAttempts; attempt++ {
		data, retry, err := downloadOnce(ctx, source, dialContext)
		if err == nil {
			return data, nil
		}
		lastErr = err
		if !retry || attempt == downloadAttempts || ctx.Err() != nil {
			break
		}
		timer := time.NewTimer(time.Duration(attempt) * 500 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
	return nil, lastErr
}

func downloadOnce(ctx context.Context, source string, dialContext DialContext) ([]byte, bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, source, nil)
	if err != nil {
		return nil, false, err
	}
	request.Header.Set("Accept", "application/json")
	request.Header.Set("User-Agent", "HongdaCore/1.10")
	transport := &http.Transport{Proxy: nil}
	if dialContext != nil {
		transport.DialContext = dialContext
	}
	client := &http.Client{Transport: transport, Timeout: downloadTimeout}
	response, err := client.Do(request)
	transport.CloseIdleConnections()
	if err != nil {
		return nil, true, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		retry := response.StatusCode == http.StatusRequestTimeout ||
			response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500
		return nil, retry, fmt.Errorf("HTTP status %d", response.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, maxSourceSize+1))
	if err != nil {
		return nil, true, err
	}
	if len(data) > maxSourceSize {
		return nil, false, fmt.Errorf("source exceeds %d bytes", maxSourceSize)
	}
	return data, false, nil
}

func cacheName(config model.RulesetConfig) string {
	safeID := strings.Map(func(r rune) rune {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_' {
			return r
		}
		return '_'
	}, config.ID)
	sum := sha256.Sum256([]byte(config.ID + "\x00" + config.URL))
	return safeID + "-" + hex.EncodeToString(sum[:6]) + ".json"
}

func readCache(path string) ([]byte, os.FileInfo, error) {
	info, err := os.Stat(path)
	if err != nil {
		return nil, nil, err
	}
	if info.Size() > maxSourceSize {
		return nil, nil, fmt.Errorf("cache exceeds size limit")
	}
	data, err := os.ReadFile(path)
	return data, info, err
}

func writeCacheAtomic(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".hongda-ruleset-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}
