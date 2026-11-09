package app

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
)

// canonicalServer answers 200 on every route the tests use, behind the
// canonical-host middleware built from cfg.
func canonicalServer(cfg config.Config) *echo.Echo {
	e := echo.New()
	e.Use(canonicalHost(cfg))
	ok := func(c *echo.Context) error { return c.String(http.StatusOK, "ok") }
	e.GET("/", ok)
	e.GET("/updates", ok)
	e.HEAD("/", ok)
	e.GET("/healthz", ok)
	e.POST("/cache/purge", ok)
	return e
}

func serve(e *echo.Echo, method, host, path string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	req.Host = host
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	return rec
}

func TestApexRedirectsToCanonicalOriginInProduction(t *testing.T) {
	e := canonicalServer(config.Config{Environment: "production", SiteURL: "https://www.example.com"})

	rec := serve(e, http.MethodGet, "example.com", "/updates?page=2")
	if rec.Code != http.StatusMovedPermanently {
		t.Fatalf("status = %d, want 301", rec.Code)
	}
	if got := rec.Header().Get("Location"); got != "https://www.example.com/updates?page=2" {
		t.Fatalf("Location = %q", got)
	}
}

func TestCanonicalHostPassesThrough(t *testing.T) {
	e := canonicalServer(config.Config{Environment: "production", SiteURL: "https://www.example.com"})

	if rec := serve(e, http.MethodGet, "www.example.com", "/"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestHealthIsNeverRedirected(t *testing.T) {
	e := canonicalServer(config.Config{Environment: "production", SiteURL: "https://www.example.com"})

	if rec := serve(e, http.MethodGet, "10.0.0.7:8080", "/healthz"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestWritesAreNeverRedirected(t *testing.T) {
	e := canonicalServer(config.Config{Environment: "production", SiteURL: "https://www.example.com"})

	if rec := serve(e, http.MethodPost, "cms-internal:80", "/cache/purge"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestHeadIsRedirectedLikeGet(t *testing.T) {
	e := canonicalServer(config.Config{Environment: "production", SiteURL: "https://www.example.com"})

	if rec := serve(e, http.MethodHead, "example.com", "/"); rec.Code != http.StatusMovedPermanently {
		t.Fatalf("status = %d, want 301", rec.Code)
	}
}

// Local and QA hosts answer on their own names; a SITE_URL there must not
// move them to the production domain.
func TestNonProductionNeverRedirects(t *testing.T) {
	for _, env := range []string{"development", "qa", ""} {
		e := canonicalServer(config.Config{Environment: env, SiteURL: "https://www.example.com"})
		if rec := serve(e, http.MethodGet, "site.test", "/"); rec.Code != http.StatusOK {
			t.Fatalf("APP_ENV=%q: status = %d, want 200", env, rec.Code)
		}
	}
}

// An unset SITE_URL is not a reason to guess a host.
func TestEmptySiteURLNeverRedirects(t *testing.T) {
	e := canonicalServer(config.Config{Environment: "production", SiteURL: ""})

	if rec := serve(e, http.MethodGet, "example.com", "/"); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}
