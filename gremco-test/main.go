// Package main wires an Echo server that serves htmx fragments rendered with
// Templ, backed by a Redis cache-aside layer in front of Cockpit CMS.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/a-h/templ"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	"github.com/redis/go-redis/v9"

	"github.com/example/gremco-test/templates"
)

// cacheTTL is how long a Cockpit response stays warm in Redis. Cockpit content
// changes rarely, so 10 minutes keeps the CMS almost entirely out of the
// request path while staying fresh enough for editorial work.
const cacheTTL = 10 * time.Minute

// articlesCacheKey namespaces the cached payload. Bump the suffix whenever the
// shape of Article changes so stale JSON is never decoded into a new struct.
const articlesCacheKey = "gremco-test:articles:v1"

// Article is the projection of a Cockpit collection item the frontend needs.
// It is a type alias, not a copy: the canonical definition lives in the
// templates package so components can take it directly with no conversion.
type Article = templates.Article

type Server struct {
	rdb *redis.Client
}

func main() {
	rdb, err := newRedisClient()
	if err != nil {
		log.Fatalf("redis: %v", err)
	}
	defer rdb.Close()

	s := &Server{rdb: rdb}

	e := echo.New()
	e.HideBanner = true
	e.Use(middleware.Recover())
	e.Use(middleware.Logger())
	e.Use(middleware.Gzip())

	e.Static("/static", "static")

	e.GET("/", s.handleIndex)
	e.GET("/articulos", s.handleArticles)     // htmx fragment
	e.POST("/cache/purge", s.handleCachePurge) // Cockpit webhook target
	e.GET("/healthz", func(c echo.Context) error {
		if err := s.rdb.Ping(c.Request().Context()).Err(); err != nil {
			return c.String(http.StatusServiceUnavailable, "redis unavailable")
		}
		return c.String(http.StatusOK, "ok")
	})

	port := env("PORT", "8080")
	go func() {
		if err := e.Start(":" + port); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("server: %v", err)
		}
	}()

	// Graceful shutdown so in-flight htmx requests are not cut mid-render.
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := e.Shutdown(ctx); err != nil {
		log.Printf("shutdown: %v", err)
	}
}

// newRedisClient parses REDIS_URL (redis://host:port/db) and verifies the
// connection up front, so a misconfigured environment fails at boot instead of
// on the first cache miss.
func newRedisClient() (*redis.Client, error) {
	opts, err := redis.ParseURL(env("REDIS_URL", "redis://gosite-redis:6379/0"))
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opts)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, err
	}
	log.Printf("redis connected: %s db=%d", opts.Addr, opts.DB)
	return rdb, nil
}

func (s *Server) handleIndex(c echo.Context) error {
	return render(c, http.StatusOK, templates.Index("gremco-test"))
}

// handleArticles is the htmx target. It reads through the Redis cache and only
// touches Cockpit when the key is cold.
func (s *Server) handleArticles(c echo.Context) error {
	ctx := c.Request().Context()
	start := time.Now()

	articles, hit, err := s.articles(ctx)
	if err != nil {
		return echo.NewHTTPError(http.StatusBadGateway, "could not load articles")
	}

	source := "MISS"
	if hit {
		source = "HIT"
	}
	// Surfaced as a response header so the cache behaviour is observable from
	// the browser devtools while developing.
	c.Response().Header().Set("X-Cache", source)
	c.Response().Header().Set("X-Cache-Elapsed", time.Since(start).String())
	log.Printf("GET /articulos cache=%s elapsed=%s", source, time.Since(start))

	return render(c, http.StatusOK, templates.ArticleList(articles, source, time.Since(start).String()))
}

// articles implements the cache-aside read path:
//
//	1. GET the key from Redis. On a hit, decode and return in microseconds.
//	2. On a miss, query Cockpit, encode the result, SET it with a TTL, return it.
//
// A Redis failure is never fatal: the CMS query is still served, just slower.
func (s *Server) articles(ctx context.Context) ([]Article, bool, error) {
	cached, err := s.rdb.Get(ctx, articlesCacheKey).Bytes()
	switch {
	case err == nil:
		var articles []Article
		if err := json.Unmarshal(cached, &articles); err == nil {
			return articles, true, nil // cache hit
		}
		// Corrupt payload: drop it and fall through to a fresh fetch.
		log.Printf("cache: discarding unreadable value for %s", articlesCacheKey)
		s.rdb.Del(ctx, articlesCacheKey)
	case errors.Is(err, redis.Nil):
		// Cache miss, expected.
	default:
		log.Printf("cache: read failed, falling back to cockpit: %v", err)
	}

	articles, err := fetchFromCockpit(ctx)
	if err != nil {
		return nil, false, err
	}

	if payload, err := json.Marshal(articles); err == nil {
		if err := s.rdb.Set(ctx, articlesCacheKey, payload, cacheTTL).Err(); err != nil {
			log.Printf("cache: write failed: %v", err)
		}
	}
	return articles, false, nil
}

// handleCachePurge lets Cockpit invalidate the cache on publish, so editors do
// not have to wait out the TTL. Protect it with the shared CMS token.
func (s *Server) handleCachePurge(c echo.Context) error {
	if token := os.Getenv("COCKPIT_API_TOKEN"); token != "" && c.Request().Header.Get("X-Api-Key") != token {
		return echo.NewHTTPError(http.StatusUnauthorized, "invalid token")
	}
	if err := s.rdb.Del(c.Request().Context(), articlesCacheKey).Err(); err != nil {
		return echo.NewHTTPError(http.StatusInternalServerError, "purge failed")
	}
	return c.String(http.StatusOK, "purged")
}

// fetchFromCockpit stands in for the real CMS call. Replace the body with an
// HTTP request to COCKPIT_URL/api/content/items/articles carrying the
// COCKPIT_API_TOKEN header; the caching layer above stays unchanged.
func fetchFromCockpit(ctx context.Context) ([]Article, error) {
	select {
	case <-time.After(400 * time.Millisecond): // simulated CMS latency
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	return []Article{
		{ID: "1", Title: "Go + htmx without a build step", Excerpt: "Server-rendered HTML, no bundler.", Slug: "go-htmx"},
		{ID: "2", Title: "Cockpit as a headless CMS", Excerpt: "Content editing without coupling the frontend.", Slug: "cockpit-headless"},
		{ID: "3", Title: "Cache-aside with Redis", Excerpt: "Keep the CMS off the hot path.", Slug: "redis-cache-aside"},
	}, nil
}

// render adapts a Templ component to an Echo response.
func render(c echo.Context, status int, component templ.Component) error {
	c.Response().Header().Set(echo.HeaderContentType, echo.MIMETextHTMLCharsetUTF8)
	c.Response().WriteHeader(status)
	return component.Render(c.Request().Context(), c.Response().Writer)
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
