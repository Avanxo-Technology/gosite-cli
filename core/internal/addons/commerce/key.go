package commerce

import (
	"context"
	"log/slog"
	"os"
	"strings"
	"sync"
	"time"
)

// DefaultKeyPath is where the seed writes the publishable key; the site mounts
// that volume read-only (design D6 of the service change).
const DefaultKeyPath = "/run/gosite-commerce/publishable_key"

// PublishableKey holds the Store API key once the seed has written it. Until
// then the store routes answer 503 while the rest of the site works (design D2).
type PublishableKey struct {
	path string

	mu            sync.RWMutex
	value         string
	missingLogged bool
}

func NewPublishableKey(path string) *PublishableKey {
	if path == "" {
		path = DefaultKeyPath
	}
	return &PublishableKey{path: path}
}

// Reload reads the file. It reports whether a usable key is now held; a missing
// or empty file leaves the previous value in place and is not an error.
func (k *PublishableKey) Reload() bool {
	raw, err := os.ReadFile(k.path)
	if err != nil {
		return false
	}
	key := strings.TrimSpace(string(raw))
	if key == "" {
		return false
	}
	k.mu.Lock()
	k.value = key
	k.mu.Unlock()
	return true
}

// Get returns the key and whether it has been loaded. Handlers serve 503 while
// ok is false.
func (k *PublishableKey) Get() (string, bool) {
	k.mu.RLock()
	defer k.mu.RUnlock()
	return k.value, k.value != ""
}

// Wait retries Reload until a key is available or ctx is done. The first
// attempt happens immediately, so a normal restart with the file already there
// never waits. A missing file is logged once, not once per attempt.
func (k *PublishableKey) Wait(ctx context.Context, interval time.Duration, log *slog.Logger) {
	if interval <= 0 {
		interval = 2 * time.Second
	}
	if k.Reload() {
		return
	}
	k.logMissingOnce(log)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if k.Reload() {
				return
			}
		}
	}
}

func (k *PublishableKey) logMissingOnce(log *slog.Logger) {
	if log == nil {
		return
	}
	k.mu.Lock()
	already := k.missingLogged
	k.missingLogged = true
	k.mu.Unlock()
	if !already {
		log.Warn("commerce: publishable key not written yet; store routes answer 503 until it is", "path", k.path)
	}
}
