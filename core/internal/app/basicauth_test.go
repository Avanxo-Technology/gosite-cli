package app

import (
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
)

func gateServer(credentials string) *echo.Echo {
	e := echo.New()
	e.Use(basicAuthGate(config.Config{BasicAuth: credentials}))
	ok := func(c *echo.Context) error { return c.String(http.StatusOK, "page") }
	e.GET("/", ok)
	e.GET("/healthz", ok)
	e.POST("/cache/purge", ok)
	return e
}

func gateRequest(e *echo.Echo, method, path, user, pass string, withAuth bool) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, nil)
	if withAuth {
		req.Header.Set("Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(user+":"+pass)))
	}
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	return rec
}

// Unset, empty or colon-less credentials leave the site public, as before.
func TestGateOffWhenCredentialsAreNotUsable(t *testing.T) {
	for _, raw := range []string{"", "nocolon", ":password", "user:"} {
		e := gateServer(raw)
		if rec := gateRequest(e, http.MethodGet, "/", "", "", false); rec.Code != http.StatusOK {
			t.Fatalf("HTTP_BASIC_CREDENTIALS=%q: status = %d, want 200", raw, rec.Code)
		}
	}
}

func TestGateRejectsMissingAndWrongCredentials(t *testing.T) {
	e := gateServer("qa:s3cret")

	missing := gateRequest(e, http.MethodGet, "/", "", "", false)
	if missing.Code != http.StatusUnauthorized {
		t.Fatalf("no credentials: status = %d, want 401", missing.Code)
	}
	if got := missing.Header().Get("WWW-Authenticate"); !strings.HasPrefix(got, "Basic ") {
		t.Fatalf("WWW-Authenticate = %q", got)
	}

	if rec := gateRequest(e, http.MethodGet, "/", "qa", "wrong", true); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong password: status = %d, want 401", rec.Code)
	}
	if rec := gateRequest(e, http.MethodGet, "/", "root", "s3cret", true); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong user: status = %d, want 401", rec.Code)
	}
}

func TestGateAcceptsCorrectCredentials(t *testing.T) {
	e := gateServer("qa:s3cret")

	if rec := gateRequest(e, http.MethodGet, "/", "qa", "s3cret", true); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

// The password may contain a colon; only the first colon separates the user.
func TestGatePasswordMayContainColon(t *testing.T) {
	e := gateServer("qa:pa:ss")

	if rec := gateRequest(e, http.MethodGet, "/", "qa", "pa:ss", true); rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
}

func TestGateExemptsHealthAndPurgeButNotPages(t *testing.T) {
	e := gateServer("qa:s3cret")

	if rec := gateRequest(e, http.MethodGet, "/healthz", "", "", false); rec.Code != http.StatusOK {
		t.Fatalf("/healthz status = %d, want 200", rec.Code)
	}
	if rec := gateRequest(e, http.MethodPost, "/cache/purge", "", "", false); rec.Code != http.StatusOK {
		t.Fatalf("/cache/purge status = %d, want 200 (keeps its own token check)", rec.Code)
	}
}

func TestGateRobotsDisallowsWithoutCredentials(t *testing.T) {
	e := gateServer("qa:s3cret")

	rec := gateRequest(e, http.MethodGet, "/robots.txt", "", "", false)
	if rec.Code != http.StatusOK {
		t.Fatalf("/robots.txt status = %d, want 200", rec.Code)
	}
	if body := rec.Body.String(); body != "User-agent: *\nDisallow: /\n" {
		t.Fatalf("robots body = %q", body)
	}
}

func TestGateSendsNoIndexOnEveryResponse(t *testing.T) {
	e := gateServer("qa:s3cret")

	for _, rec := range []*httptest.ResponseRecorder{
		gateRequest(e, http.MethodGet, "/", "", "", false),
		gateRequest(e, http.MethodGet, "/", "qa", "s3cret", true),
	} {
		if got := rec.Header().Get("X-Robots-Tag"); got != "noindex, nofollow, noarchive" {
			t.Fatalf("X-Robots-Tag = %q (status %d)", got, rec.Code)
		}
	}
}
