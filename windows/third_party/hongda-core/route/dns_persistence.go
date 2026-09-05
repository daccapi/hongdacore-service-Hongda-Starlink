package route

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

const (
	dnsCacheFileName = "dns-cache-v1.dat"
	dnsCacheVersion  = 2
)

var dnsCacheMagic = []byte("HDC1")

type persistedDNSCache struct {
	Version int                      `json:"version"`
	Entries []persistedDNSCacheEntry `json:"entries"`
}

type persistedDNSCacheEntry struct {
	Key      []byte `json:"key"`
	Response []byte `json:"response"`
	Expires  int64  `json:"expires"`
	StoredAt int64  `json:"stored_at"`
}

// EnableDNSPersistence restores live TTL entries and starts a low-frequency
// writer. Corrupt or foreign-user DPAPI data is ignored because a cache must
// never prevent the proxy runtime from starting.
func (r *Router) EnableDNSPersistence(cacheDir string) {
	cacheDir = filepath.Clean(cacheDir)
	if cacheDir == "." || cacheDir == "" || r.dnsPersistStop != nil {
		return
	}
	r.dnsPersistPath = filepath.Join(cacheDir, dnsCacheFileName)
	r.loadDNSCache()
	stop := make(chan struct{})
	r.dnsPersistStop = stop
	r.dnsPersistWG.Add(1)
	go func() {
		defer r.dnsPersistWG.Done()
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				r.persistDNSCache()
			case <-stop:
				r.persistDNSCache()
				return
			}
		}
	}()
}

func (r *Router) loadDNSCache() {
	data, err := os.ReadFile(r.dnsPersistPath)
	if err != nil || len(data) <= len(dnsCacheMagic) || !bytes.Equal(data[:len(dnsCacheMagic)], dnsCacheMagic) {
		return
	}
	plaintext, err := unprotectDNSCache(data[len(dnsCacheMagic):])
	if err != nil {
		return
	}
	var document persistedDNSCache
	if json.Unmarshal(plaintext, &document) != nil || document.Version != dnsCacheVersion {
		return
	}
	now := time.Now()
	r.dnsMu.Lock()
	defer r.dnsMu.Unlock()
	for _, entry := range document.Entries {
		if len(r.dnsMessages) >= 4096 || len(entry.Key) < 76 || !dnsResponseCacheable(entry.Response) {
			continue
		}
		expires := time.UnixMilli(entry.Expires)
		storedAt := time.UnixMilli(entry.StoredAt)
		ttl := dnsResponseCacheTTL(entry.Response)
		if ttl <= 0 || storedAt.After(now) || !expires.After(now) || expires.After(storedAt.Add(ttl)) {
			continue
		}
		key := string(entry.Key)
		if _, err := hex.DecodeString(string(entry.Key[:64])); err != nil {
			continue
		}
		if dnsMessageKey(entry.Key[64:]) != string(entry.Key[64:]) {
			continue
		}
		r.dnsMessages[key] = dnsMessageCacheEntry{
			response: dnsResponseForQuery(entry.Response, nil),
			storedAt: storedAt,
			expires:  expires,
		}
	}
}

func (r *Router) persistDNSCache() {
	r.dnsMu.Lock()
	if !r.dnsPersistDirty || r.dnsPersistPath == "" {
		r.dnsMu.Unlock()
		return
	}
	now := time.Now()
	document := persistedDNSCache{Version: dnsCacheVersion}
	for key, entry := range r.dnsMessages {
		if !entry.expires.After(now) {
			continue
		}
		document.Entries = append(document.Entries, persistedDNSCacheEntry{
			Key:      []byte(key),
			Response: append([]byte(nil), entry.response...),
			Expires:  entry.expires.UnixMilli(),
			StoredAt: entry.storedAt.UnixMilli(),
		})
	}
	r.dnsPersistDirty = false
	r.dnsMu.Unlock()

	plaintext, err := json.Marshal(document)
	if err != nil {
		r.markDNSPersistenceDirty()
		return
	}
	protected, err := protectDNSCache(plaintext)
	if err != nil {
		r.markDNSPersistenceDirty()
		return
	}
	if err := os.MkdirAll(filepath.Dir(r.dnsPersistPath), 0o700); err != nil {
		r.markDNSPersistenceDirty()
		return
	}
	temporary := r.dnsPersistPath + ".tmp"
	payload := append(append([]byte(nil), dnsCacheMagic...), protected...)
	if err := os.WriteFile(temporary, payload, 0o600); err != nil {
		r.markDNSPersistenceDirty()
		return
	}
	_ = os.Remove(r.dnsPersistPath)
	if err := os.Rename(temporary, r.dnsPersistPath); err != nil {
		_ = os.Remove(temporary)
		r.markDNSPersistenceDirty()
	}
}

func (r *Router) markDNSPersistenceDirty() {
	r.dnsMu.Lock()
	r.dnsPersistDirty = true
	r.dnsMu.Unlock()
}

func (r *Router) stopDNSPersistence() {
	r.dnsMu.Lock()
	stop := r.dnsPersistStop
	r.dnsPersistStop = nil
	r.dnsMu.Unlock()
	if stop == nil {
		return
	}
	close(stop)
	r.dnsPersistWG.Wait()
}
