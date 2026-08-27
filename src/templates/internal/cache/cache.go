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
	if len(keys) == 0 {
		return nil
	}
	all := make([]string, 0, len(keys)*2)
	for _, k := range keys {
		all = append(all, k, staleKey(k))
	}
	return c.rdb.Del(ctx, all...).Err()
}

// purgeScanCount is how many keys each SCAN round asks for. Redis treats it as
// a hint about how much work one round may do, so it trades round-trips against
// how long the server is busy in any single call.
const purgeScanCount = 200

// PurgeAll drops every page this project has cached.
//
// For a change to something the layout carries - analytics keys, a site-wide
// setting - "purge what changed" is the whole site, because that content is on
// every page. Anything narrower leaves pages serving values that no longer
// exist.
//
// The prefix is what keeps this from being a cache flush: several projects
// share one Redis, and one project's purge must never touch another's.
func (c *Cache) PurgeAll(ctx context.Context, projectPrefix string) error {
	return c.PurgeGroup(ctx, projectPrefix)
}

// PurgeGroup removes every key starting with prefix, fresh and stale alike.
//
// A page that exists once - the home page - is purged by name. A blog is many
// keys instead: an article per slug and an index per page number, and
// publishing one article changes what the index lists. Naming them all is not
// possible from here, so the group is addressed by its prefix.
//
// SCAN is used rather than KEYS: KEYS walks the whole keyspace in one blocking
// call, which on a shared Redis stalls every other user of it. SCAN is
// incremental and cursor-based, so a large keyspace costs more round-trips
// instead of one long stall.
//
// Deletion happens in batches as the scan proceeds, so memory stays bounded no
// matter how many keys match.
func (c *Cache) PurgeGroup(ctx context.Context, prefix string) error {
	if prefix == "" {
		// Refuse to interpret an empty prefix as "everything": that would let a
		// caller with a missing value flush the whole cache by accident.
		return nil
	}

	var (
		cursor uint64
		batch  []string
	)

	for {
		keys, next, err := c.rdb.Scan(ctx, cursor, prefix+"*", purgeScanCount).Result()
		if err != nil {
			return err
		}

		batch = append(batch, keys...)

		if len(batch) >= purgeScanCount {
			if err := c.rdb.Del(ctx, batch...).Err(); err != nil {
				return err
			}
			batch = batch[:0]
		}

		cursor = next
		if cursor == 0 {
			break
		}
	}

	if len(batch) > 0 {
		if err := c.rdb.Del(ctx, batch...).Err(); err != nil {
			return err
		}
	}

	return nil
}
