package handlers_test

import (
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"__MODULE__/internal/app"
	"__MODULE__/internal/config"
	"github.com/labstack/echo/v5"
)

func newApp(t *testing.T, cms http.HandlerFunc) *echo.Echo {
	t.Helper()
	url := os.Getenv("REDIS_TEST_URL")
	if url == "" {
		t.Skip("REDIS_TEST_URL is not set")
	}
	srv := httptest.NewServer(cms)
	t.Cleanup(srv.Close)

	a, err := app.NewApp(config.Config{
		CockpitURL: srv.URL, RedisURL: url, Environment: "production",
	}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	a.Redis.FlushDB(t.Context())
	return app.NewRouter(a)
}

func get(t *testing.T, e *echo.Echo) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	return rec
}

// A project whose CMS has no "home" singleton yet is not a broken project.
func TestMissingHomeSingletonRendersFallbacks(t *testing.T) {
	e := newApp(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNotFound) })

	rec := get(t, e)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 (was 502 before)", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Your site is running") {
		t.Error("the template fallback text is missing")
	}
}

// An existing but empty singleton is the same situation.
func TestEmptyHomeSingletonRendersFallbacks(t *testing.T) {
	e := newApp(t, func(w http.ResponseWriter, r *http.Request) { w.Write([]byte(`{}`)) })

	if code := get(t, e).Code; code != http.StatusOK {
		t.Fatalf("status = %d, want 200", code)
	}
}

// The fallback page must not be cached: the real content has to appear as soon
// as somebody writes it, not a TTL later.
func TestFallbackPageIsNotCached(t *testing.T) {
	e := newApp(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNotFound) })

	get(t, e)
	if h := get(t, e).Header().Get("X-Cache"); h == "HIT" {
		t.Error("the fallback page was cached")
	}
}

// A CMS that is actually broken must still be a 502, not a page pretending to
// be fine.
func TestUnreachableCMSIsStill502(t *testing.T) {
	e := newApp(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusInternalServerError) })

	if code := get(t, e).Code; code != http.StatusBadGateway {
		t.Errorf("status = %d, want 502", code)
	}
}
