package cache

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newTestCache(t *testing.T) (*Cache, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	return New(rdb, slog.New(slog.NewTextHandler(io.Discard, nil)), false), mr
}

func page() ([]byte, error) { return []byte(strings.Repeat("x", minRenderSize)), nil }

func TestHTMLWritesTheStaleCopy(t *testing.T) {
	c, mr := newTestCache(t)
	if _, _, err := c.HTML(context.Background(), "p:page:/", page); err != nil {
		t.Fatal(err)
	}
	if !mr.Exists("p:page:/:stale") {
		t.Error("HTML did not write the stale copy")
	}
}

// A crawler walking query variants must not leave one 24-hour copy per URL.
func TestHTMLWithoutStaleWritesOnlyTheFreshKey(t *testing.T) {
	c, mr := newTestCache(t)
	if _, _, err := c.HTMLWithoutStale(context.Background(), "p:page:/list?sort=a", page); err != nil {
		t.Fatal(err)
	}
	if !mr.Exists("p:page:/list?sort=a") {
		t.Error("fresh key missing")
	}
	if mr.Exists("p:page:/list?sort=a:stale") {
		t.Error("HTMLWithoutStale wrote a stale copy")
	}
	if got := mr.TTL("p:page:/list?sort=a"); got != ttl {
		t.Errorf("fresh TTL = %v, want %v", got, ttl)
	}
}

func TestHTMLWithoutStaleStillServesAnExistingStaleCopy(t *testing.T) {
	if testing.Short() {
		t.Skip("waits for the render retries")
	}
	c, mr := newTestCache(t)
	if err := mr.Set("p:page:/list?sort=a:stale", "old copy"); err != nil {
		t.Fatal(err)
	}
	fail := func() ([]byte, error) { return nil, errors.New("cms down") }
	got, _, err := c.HTMLWithoutStale(context.Background(), "p:page:/list?sort=a", fail)
	if err != nil || string(got) != "old copy" {
		t.Errorf("got %q, %v; want the existing stale copy", got, err)
	}
}
