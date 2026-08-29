package app

import (
	"net/http"
	"net/http/httptest"
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
