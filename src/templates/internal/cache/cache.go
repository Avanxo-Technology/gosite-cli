// Package cache is a small cache-aside helper over Redis.
package cache

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"
)

// ttl keeps Cockpit almost entirely out of the request path while staying
// fresh enough for editorial work. Publishing calls /cache/purge anyway.
const ttl = 10 * time.Minute

// staleTTL keeps a good render around beyond the fresh TTL so visitors see
// slightly outdated content rather than a 502 when the CMS is temporarily
// unreachable.
const staleTTL = 24 * time.Hour

type Cache struct {
	rdb *redis.Client
	log *slog.Logger
	dev bool

	// sf collapses concurrent cold renders of the same key into a single one,
	// so an expired cache under load never turns into a stampede against the
	// CMS: one request renders, the rest wait and share its result.
	sf singleflight.Group
}

func New(rdb *redis.Client, log *slog.Logger, dev bool) *Cache {
	return &Cache{rdb: rdb, log: log, dev: dev}
}

// staleKey appends ":stale" so the long-lived copy lives beside the fresh one.
func staleKey(key string) string { return key + ":stale" }

// HTML returns the cached bytes for key, calling render only on a miss:
//
//  1. GET the key. On a hit, return immediately — no CMS call, no rendering.
//  2. On a miss, run render behind single-flight, SET the result with a TTL
//     and return it. Concurrent misses of the same key share that one render.
//
// If a render fails, the stale copy (if any) is served instead so visitors
// never see a 502 while the CMS warms up (stale-if-error).
//
// A Redis failure is never fatal: render still runs and the request is just
// slower, which keeps the site up when the cache is down.
//
// In development mode (dev=true) the cache is bypassed entirely — every
// request renders fresh, which makes iteration faster and avoids stale pages.
func (c *Cache) HTML(ctx context.Context, key string, render func() ([]byte, error)) ([]byte, bool, error) {
	start := time.Now()

	// Bypass cache entirely in development — always render fresh.
	if c.dev {
		html, err := render()
		if err != nil {
			return nil, false, err
		}
		c.log.Debug("dev bypass", "key", key, "elapsed", time.Since(start))
		return html, false, nil
	}

	cached, err := c.rdb.Get(ctx, key).Bytes()
	if err == nil {
		c.log.Info("cache hit", "key", key, "elapsed", time.Since(start))
		return cached, true, nil
	}
	if !errors.Is(err, redis.Nil) {
		c.log.Warn("cache read failed, rendering anyway", "key", key, "err", err)
	}

	v, err, shared := c.sf.Do(key, func() (any, error) {
		fresh, err := render()
		if err != nil {
			// Render failed — serve the last good copy so visitors don't see
			// a 502 while the CMS warms up. single-flight discards this
			// result so the next caller retries the render.
			stale, staleErr := c.rdb.Get(context.Background(), staleKey(key)).Bytes()
			if staleErr == nil {
				c.log.Warn("render failed, serving stale", "key", key, "err", err)
				return stale, nil
			}
			return nil, err
		}

		// Write with a background context, not the request one: the caller
		// that happened to win the race may disconnect, and that must not
		// stop the cache from being warmed for everyone else.
		bg := context.Background()
		if err := c.rdb.Set(bg, key, fresh, ttl).Err(); err != nil {
			c.log.Warn("cache write failed", "key", key, "err", err)
		}
		if err := c.rdb.Set(bg, staleKey(key), fresh, staleTTL).Err(); err != nil {
			c.log.Warn("stale cache write failed", "key", key, "err", err)
		}
		return fresh, nil
	})
	if err != nil {
		return nil, false, err
	}

	c.log.Info("cache miss", "key", key, "shared", shared, "elapsed", time.Since(start))
	return v.([]byte), false, nil
}

// Purge removes fresh and stale keys so an editor never has to wait out the
// TTL and stale content is cleared alongside fresh content.
func (c *Cache) Purge(ctx context.Context, keys ...string) error {
	all := make([]string, 0, len(keys)*2)
	for _, k := range keys {
		all = append(all, k, staleKey(k))
	}
	return c.rdb.Del(ctx, all...).Err()
}
