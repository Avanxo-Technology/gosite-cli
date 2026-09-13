package gosite

import (
	"context"
	"time"

	"github.com/redis/go-redis/v9"
)

// State is Redis storage for application data, namespaced under
// "<project>:app:".
//
// It exists because the page cache owns "<project>:cache:" and a site-wide
// purge sweeps that prefix. Data that is not cache - a vote limit, the last
// good value of an external feed - stored next to it is deleted by the next
// editor who publishes. Keys passed to State are relative; the prefix is added
// here and never needs to appear in site code.
type State struct {
	rdb    *redis.Client
	prefix string
}

func newState(rdb *redis.Client, prefix string) *State {
	return &State{rdb: rdb, prefix: prefix}
}

// Key is the full Redis key for a relative key.
func (s *State) Key(key string) string { return s.prefix + key }

// Get returns the value, or redis.Nil when the key does not exist.
func (s *State) Get(ctx context.Context, key string) (string, error) {
	return s.rdb.Get(ctx, s.Key(key)).Result()
}

// Set stores a value. A zero ttl keeps it until deleted.
func (s *State) Set(ctx context.Context, key string, value any, ttl time.Duration) error {
	return s.rdb.Set(ctx, s.Key(key), value, ttl).Err()
}

// SetNX stores a value only if the key does not exist, reporting whether it did.
func (s *State) SetNX(ctx context.Context, key string, value any, ttl time.Duration) (bool, error) {
	return s.rdb.SetNX(ctx, s.Key(key), value, ttl).Result()
}

// Incr increments an integer counter and returns the new value.
func (s *State) Incr(ctx context.Context, key string) (int64, error) {
	return s.rdb.Incr(ctx, s.Key(key)).Result()
}

// Expire sets a key's time to live.
func (s *State) Expire(ctx context.Context, key string, ttl time.Duration) error {
	return s.rdb.Expire(ctx, s.Key(key), ttl).Err()
}

// TTL returns a key's remaining time to live.
func (s *State) TTL(ctx context.Context, key string) (time.Duration, error) {
	return s.rdb.TTL(ctx, s.Key(key)).Result()
}

// Del deletes keys.
func (s *State) Del(ctx context.Context, keys ...string) error {
	full := make([]string, len(keys))
	for i, k := range keys {
		full[i] = s.Key(k)
	}
	return s.rdb.Del(ctx, full...).Err()
}
