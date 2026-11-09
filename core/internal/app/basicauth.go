package app

import (
	"crypto/subtle"
	"net/http"
	"strings"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
)

// basicAuthGate protects a whole deployment (QA, staging) with HTTP Basic
// Authentication. It is off unless HTTP_BASIC_CREDENTIALS holds "user:password";
// an empty or malformed value leaves the site public.
//
// When on, every response carries X-Robots-Tag noindex, and /robots.txt
// disallows all crawling without asking for credentials, so a search engine
// that finds the hostname cannot index it. /healthz is open for the deploy
// platform, and /cache/purge keeps its own token check.
func basicAuthGate(cfg config.Config) echo.MiddlewareFunc {
	user, pass, ok := parseBasicCredentials(cfg.BasicAuth)
	if !ok {
		return func(next echo.HandlerFunc) echo.HandlerFunc { return next }
	}

	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c *echo.Context) error {
			c.Response().Header().Set("X-Robots-Tag", "noindex, nofollow, noarchive")

			switch c.Request().URL.Path {
			case "/healthz", "/cache/purge":
				return next(c)
			case "/robots.txt":
				return c.Blob(http.StatusOK, "text/plain", []byte("User-agent: *\nDisallow: /\n"))
			}

			u, p, has := c.Request().BasicAuth()
			// ConstantTimeCompare on both fields, always evaluated, so the
			// comparison time does not reveal which one was wrong.
			userOK := subtle.ConstantTimeCompare([]byte(u), []byte(user)) == 1
			passOK := subtle.ConstantTimeCompare([]byte(p), []byte(pass)) == 1
			if has && userOK && passOK {
				return next(c)
			}

			c.Response().Header().Set("WWW-Authenticate", `Basic realm="restricted"`)
			return c.NoContent(http.StatusUnauthorized)
		}
	}
}

// parseBasicCredentials splits "user:password" at the first colon. The user
// cannot contain a colon, the password can. Both parts must be non-empty.
func parseBasicCredentials(raw string) (user, pass string, ok bool) {
	user, pass, found := strings.Cut(raw, ":")
	if !found || user == "" || pass == "" {
		return "", "", false
	}
	return user, pass, true
}
