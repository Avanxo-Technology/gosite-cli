package gosite

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"testing/fstest"
	"time"

	"github.com/alicebob/miniredis/v2"

	"github.com/Avanxo-Technology/gosite-cli/core/cms"
)

// testSite is an App whose optional interfaces are switched on per test.
type testSite struct {
	routes     func(r Router)
	middleware []Middleware
	purges     int
}

func (s *testSite) Routes(r Router) {
	if s.routes != nil {
		s.routes(r)
	}
}

type purgingSite struct{ *testSite }

func (s purgingSite) OnPurge(ctx context.Context) error { s.purges++; return nil }

type middlewareSite struct{ *testSite }

func (s middlewareSite) Middleware() []Middleware { return s.middleware }

// newTestServer runs core against an in-memory Redis and a stub CMS that
// answers every request with an empty object.
func newTestServer(t *testing.T, site App, opts ...Option) (*Server, *miniredis.Miniredis) {
	t.Helper()
	return newTestServerCMS(t, site, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{}`))
	}, opts...)
}

func newTestServerCMS(t *testing.T, site App, cmsHandler http.HandlerFunc, opts ...Option) (*Server, *miniredis.Miniredis) {
	t.Helper()
	mr := miniredis.RunT(t)
	cms := httptest.NewServer(cmsHandler)
	t.Cleanup(cms.Close)

	t.Setenv("GOSITE_PROJECT", "demo")
	t.Setenv("REDIS_URL", "redis://"+mr.Addr()+"/0")
	t.Setenv("COCKPIT_URL", cms.URL)
	t.Setenv("APP_ENV", "development")
	if os.Getenv("GOSITE_CONFIG") == "" {
		t.Setenv("GOSITE_CONFIG", filepath.Join(t.TempDir(), "none.yml"))
	}

	opts = append([]Option{WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil)))}, opts...)
	s, err := New(site, opts...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s, mr
}

func do(t *testing.T, s *Server, method, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	var req *http.Request
	if body == "" {
		req = httptest.NewRequest(method, path, nil)
	} else {
		req = httptest.NewRequest(method, path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, req)
	return rec
}

// routed reports whether a handler answered, as opposed to the router's
// not-found reply (404 with a JSON message).
func routed(rec *httptest.ResponseRecorder) bool {
	return rec.Code != http.StatusNotFound || rec.Body.Len() == 0
}

func TestMinimalSiteGetsCoreRoutes(t *testing.T) {
	site := &testSite{routes: func(r Router) {
		r.GET("/about", func(c *Context) error { return c.String(http.StatusOK, "about") })
	}}
	s, _ := newTestServer(t, site)

	if rec := do(t, s, http.MethodGet, "/about", ""); rec.Code != http.StatusOK || rec.Body.String() != "about" {
		t.Fatalf("/about = %d %q", rec.Code, rec.Body.String())
	}
	// /sitemap.xml and /llms.txt answer an empty 404 themselves while the CMS
	// has no Site URL or llms text, so "routed" means: not the router's own
	// not-found reply, which carries a body.
	for _, path := range []string{"/healthz", "/robots.txt", "/sitemap.xml", "/llms.txt"} {
		if !routed(do(t, s, http.MethodGet, path, "")) {
			t.Errorf("%s: no core handler", path)
		}
	}
	if rec := do(t, s, http.MethodPost, "/cache/purge", ""); rec.Code != http.StatusOK {
		t.Errorf("POST /cache/purge: status %d", rec.Code)
	}
}

func TestSiteRouteReplacesCoreRoute(t *testing.T) {
	site := &testSite{routes: func(r Router) {
		r.GET("/robots.txt", func(c *Context) error { return c.String(http.StatusOK, "site robots") })
	}}
	s, _ := newTestServer(t, site)

	if rec := do(t, s, http.MethodGet, "/robots.txt", ""); rec.Body.String() != "site robots" {
		t.Fatalf("/robots.txt = %q, want the site's handler", rec.Body.String())
	}
}

func TestWithoutRoutesDisablesCoreRoute(t *testing.T) {
	s, _ := newTestServer(t, &testSite{}, WithoutRoutes(RouteLLMs))

	if routed(do(t, s, http.MethodGet, "/llms.txt", "")) {
		t.Fatal("/llms.txt is still served")
	}
}

func TestGroupKeepsPrefixAndServices(t *testing.T) {
	site := &testSite{routes: func(r Router) {
		api := r.Group("/api")
		if api.CMS() == nil || api.State() == nil {
			t.Error("a group must expose the same CMS and State")
		}
		api.GET("/ping", func(c *Context) error { return c.String(http.StatusOK, "pong") })
	}}
	s, _ := newTestServer(t, site)

	if rec := do(t, s, http.MethodGet, "/api/ping", ""); rec.Body.String() != "pong" {
		t.Fatalf("/api/ping = %q", rec.Body.String())
	}
}

func TestMiddlewareIsApplied(t *testing.T) {
	base := &testSite{middleware: []Middleware{func(next HandlerFunc) HandlerFunc {
		return func(c *Context) error {
			c.Response().Header().Set("X-Site", "yes")
			return next(c)
		}
	}}}
	s, _ := newTestServer(t, middlewareSite{base})

	if rec := do(t, s, http.MethodGet, "/healthz", ""); rec.Header().Get("X-Site") != "yes" {
		t.Fatal("site middleware did not run")
	}
}

func TestPurgerRunsOnceAfterEachPurge(t *testing.T) {
	base := &testSite{}
	s, _ := newTestServer(t, purgingSite{base})

	do(t, s, http.MethodPost, "/cache/purge", `{"scope":"all"}`)
	if base.purges != 1 {
		t.Fatalf("site-wide purge: OnPurge ran %d times, want 1", base.purges)
	}
	do(t, s, http.MethodPost, "/cache/purge", "")
	if base.purges != 2 {
		t.Fatalf("narrow purge: OnPurge ran %d times in total, want 2", base.purges)
	}
}

// The failure this namespace exists for: a site's vote limits and last good
// values were stored under the project prefix, and an editor publishing wiped
// them.
func TestPurgeKeepsAppState(t *testing.T) {
	var state *State
	site := &testSite{routes: func(r Router) { state = r.State() }}
	s, mr := newTestServer(t, site)
	ctx := context.Background()

	if err := state.Set(ctx, "votes:1.2.3.4", "1", time.Hour); err != nil {
		t.Fatal(err)
	}
	mr.Set("demo:cache:page", "cached")
	if got := state.Key("votes:1.2.3.4"); got != "demo:app:votes:1.2.3.4" {
		t.Fatalf("state key = %q", got)
	}

	if rec := do(t, s, http.MethodPost, "/cache/purge", `{"scope":"all"}`); rec.Code != http.StatusOK {
		t.Fatalf("purge: status %d", rec.Code)
	}

	if mr.Exists("demo:cache:page") {
		t.Error("the site-wide purge left a cache key")
	}
	if !mr.Exists("demo:app:votes:1.2.3.4") {
		t.Fatal("the site-wide purge deleted application state")
	}
	if ttl := mr.TTL("demo:app:votes:1.2.3.4"); ttl != time.Hour {
		t.Errorf("state TTL = %v, want it unchanged at 1h", ttl)
	}
}

func TestUnreachableRedisFailsAtStartup(t *testing.T) {
	t.Setenv("REDIS_URL", "redis://127.0.0.1:1/0")
	if _, err := New(&testSite{}, WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil)))); err == nil {
		t.Fatal("New succeeded with Redis unreachable")
	}
}

type dataSite struct{ *testSite }

func (dataSite) TemplateData(c *Context, page string) map[string]any {
	return map[string]any{"Brand": "Acme", "Page": page}
}

// A site renders its own theme with Page, gets .Data from TemplateData, and a
// cms.Content-shaped map reaches helpers as a plain map.
func TestRenderPageWithThemeAndTemplateData(t *testing.T) {
	theme := fstest.MapFS{
		"layout.html": {Data: []byte(`{{define "layout"}}<html lang="{{htmlLang .Path .SEOData}}"><head>{{template "gosite:head" .}}</head>` +
			`<body>{{template "gosite:body-start" .}}{{template "content" .}}{{template "gosite:body-end" .}}</body></html>{{end}}`)},
		"pages/about.html": {Data: []byte(`{{define "content"}}{{.Data.Brand}}|{{.Data.Page}}|{{.Data.Extra}}|{{index .Content "headline"}}|{{.Path}}{{end}}`)},
	}
	base := &testSite{}
	base.routes = func(r Router) {
		r.GET("/about", func(c *Context) error {
			return r.Render(c, http.StatusOK, "about", Page{
				Title:   "About",
				Content: cms.Content{"headline": "Hello"},
				Data:    map[string]any{"Extra": "x"},
			})
		})
	}
	s, _ := newTestServer(t, dataSite{base}, WithTheme(theme))

	rec := do(t, s, http.MethodGet, "/about", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Acme|about|x|Hello|/about") {
		t.Errorf("page data not rendered as expected: %s", body)
	}
	if !strings.Contains(body, "<title>About</title>") {
		t.Errorf("gosite:head did not render the title: %s", body)
	}
}

func writeSiteConfig(t *testing.T, body string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gosite.yml")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GOSITE_CONFIG", path)
}

// Blog's routes exist exactly when gosite.yml lists it. Both cases answer 404
// (the stub CMS knows no blog), so the difference is whether the blog asked
// the CMS for one.
func TestAddonsFromSiteConfig(t *testing.T) {
	askedForBlogs := func(t *testing.T, config string) bool {
		writeSiteConfig(t, config)
		var asked atomic.Bool
		s, _ := newTestServerCMS(t, &testSite{}, func(w http.ResponseWriter, r *http.Request) {
			if strings.HasSuffix(r.URL.Path, "/blogs") {
				asked.Store(true)
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"data":[],"meta":{"total":0}}`))
		})
		do(t, s, http.MethodGet, "/noticias/hola", "")
		return asked.Load()
	}
	if !askedForBlogs(t, "project: demo\naddons:\n  - Blog\n") {
		t.Error("Blog is listed but /:blog/:slug did not reach the blog")
	}
	if askedForBlogs(t, "project: demo\naddons: []\n") {
		t.Error("Blog is not listed but /:blog/:slug reached the blog")
	}
}

func TestUnknownAddonFailsStartup(t *testing.T) {
	writeSiteConfig(t, "addons:\n  - Blgo\n")
	mr := miniredis.RunT(t)
	t.Setenv("REDIS_URL", "redis://"+mr.Addr()+"/0")
	_, err := New(&testSite{}, WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
	if err == nil || !strings.Contains(err.Error(), `"Blgo"`) || !strings.Contains(err.Error(), "Blog") {
		t.Fatalf("err = %v, want it to name the unknown addon and the library", err)
	}
}
