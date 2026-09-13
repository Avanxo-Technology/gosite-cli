package app

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"
)

// The uptime check pings with HEAD. Echo answers 405 to a HEAD on a GET-only
// route unless AutoHandleHEAD is on, which reports a perfectly healthy site as
// broken - so this asserts the router config rather than trusting a comment.
func TestHEADMatchesGETRoutes(t *testing.T) {
	e := echo.NewWithConfig(echo.Config{
		Router: echo.NewRouter(echo.RouterConfig{AutoHandleHEAD: true}),
	})
	e.GET("/", func(c *echo.Context) error {
		return c.String(http.StatusOK, "hello")
	})

	for _, method := range []string{http.MethodGet, http.MethodHead} {
		t.Run(method, func(t *testing.T) {
			rec := httptest.NewRecorder()
			e.ServeHTTP(rec, httptest.NewRequest(method, "/", nil))

			if rec.Code != http.StatusOK {
				t.Fatalf("%s /: status %d, want 200", method, rec.Code)
			}
			// HEAD keeps the headers and drops the body, per HTTP semantics.
			if method == http.MethodHead && rec.Body.Len() != 0 {
				t.Errorf("HEAD must send no body, got %d bytes", rec.Body.Len())
			}
			if method == http.MethodGet && rec.Body.String() != "hello" {
				t.Errorf("GET body = %q", rec.Body.String())
			}
		})
	}
}

// POST routes stay POST-only: HEAD must not reach anything that mutates state.
func TestHEADDoesNotReachPOSTRoutes(t *testing.T) {
	e := echo.NewWithConfig(echo.Config{
		Router: echo.NewRouter(echo.RouterConfig{AutoHandleHEAD: true}),
	})
	e.POST("/cache/purge", func(c *echo.Context) error {
		t.Error("a HEAD request reached a POST handler")
		return c.NoContent(http.StatusOK)
	})

	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, httptest.NewRequest(http.MethodHead, "/cache/purge", nil))

	// 405 in isolation, 404 once other routes share the tree - which of the two
	// echo picks is incidental. What matters is that the handler above never
	// ran and the caller was not told OK.
	if rec.Code == http.StatusOK {
		t.Errorf("HEAD on a POST route answered 200")
	}
}

// The two asset prefixes get deliberately different lifetimes, and the
// difference is the whole point: /static/ is served under stable names, so
// marking it immutable would pin a stale stylesheet or script in returning
// browsers for a year, with no way to invalidate it short of renaming the
// file. Cockpit uploads do carry a unique name per upload, so those are safe
// to freeze.
func TestAssetCacheHeaders(t *testing.T) {
	e := echo.New()
	e.Use(assetCacheHeaders())
	e.GET("/*", func(c *echo.Context) error {
		return c.String(http.StatusOK, "asset")
	})

	cases := []struct {
		path string
		want string
	}{
		{"/storage/uploads/2024/photo-abc123.jpg", "public, max-age=31536000, immutable"},
		{"/static/styles.css", "public, max-age=3600"},
		{"/static/js/analytics/analytics.js", "public, max-age=3600"},
		{"/", ""},
		{"/blog/some-post", ""},
	}

	for _, tc := range cases {
		t.Run(tc.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			e.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tc.path, nil))

			if got := rec.Header().Get("Cache-Control"); got != tc.want {
				t.Errorf("Cache-Control = %q, want %q", got, tc.want)
			}
		})
	}
}

// Core's consent and analytics scripts come from the module, not from a copy
// in the site's static/ that would drift from the partials that link to them.
func TestCoreAssetsServedFromModule(t *testing.T) {
	e := echo.NewWithConfig(echo.Config{
		Router: echo.NewRouter(echo.RouterConfig{AutoHandleHEAD: true, AllowOverwritingRoute: true}),
	})
	mountCoreAssets(e)

	for path, wantType := range map[string]string{
		"/static/js/analytics/consent.js":   "javascript",
		"/static/js/analytics/analytics.js": "javascript",
		"/static/css/consent.css":           "text/css",
	} {
		rec := httptest.NewRecorder()
		e.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK || rec.Body.Len() == 0 {
			t.Errorf("%s: status %d, %d bytes", path, rec.Code, rec.Body.Len())
		}
		if ct := rec.Header().Get("Content-Type"); !strings.Contains(ct, wantType) {
			t.Errorf("%s: Content-Type %q, want %s", path, ct, wantType)
		}
	}
}
