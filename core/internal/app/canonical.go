package app

import (
	"net/http"
	"net/url"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
)

// canonicalHost answers a GET or HEAD for a host other than SITE_URL's with a
// 301 to the same path on the canonical origin. Without it an apex and a www
// host serve the same pages, and search engines split the crawl between them.
//
// It runs only when APP_ENV is production - the production compose sets it, and
// local (development) and qa never redirect - and only when SITE_URL is set to
// an absolute origin. Anything else passes through unchanged, so a missing
// SITE_URL can never send a request away from the host it arrived on.
//
// /healthz and the purge endpoint are exempt: the deploy platform polls the
// health check on its own internal host, and Cockpit posts purges to the
// container address. Only reads are redirected; a write is never bounced.
func canonicalHost(cfg config.Config) echo.MiddlewareFunc {
	canonical, err := url.Parse(cfg.SiteURL)
	if cfg.Environment != "production" || err != nil || canonical.Host == "" {
		return func(next echo.HandlerFunc) echo.HandlerFunc { return next }
	}

	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c *echo.Context) error {
			req := c.Request()
			if req.Method != http.MethodGet && req.Method != http.MethodHead {
				return next(c)
			}
			if req.URL.Path == "/healthz" || req.Host == canonical.Host {
				return next(c)
			}
			return c.Redirect(http.StatusMovedPermanently, cfg.SiteURL+req.URL.RequestURI())
		}
	}
}
