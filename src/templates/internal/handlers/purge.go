package handlers

import (
	"context"
	"crypto/subtle"
	"net/http"

	"github.com/labstack/echo/v5"
)

// PurgeCache drops the cached page. It is both the target of the htmx button
// on the page and a webhook Cockpit can call when an editor publishes, so the
// site updates without waiting out the TTL.
//
// Authentication fails closed: a missing token is treated as "purging must not
// happen", never as "no authentication required". In any non-development
// environment the endpoint therefore requires a configured COCKPIT_API_TOKEN -
// with no token configured it responds 503 rather than serving unauthenticated
// purges, and a supplied-but-wrong token is 401. Token comparison is
// constant-time so timing cannot leak the secret. Development keeps its
// convenience: the on-page button posts without a header and still works.
func (h *Handlers) PurgeCache(c *echo.Context) error {

	if !h.Config.IsDev() {

		if h.Config.CockpitToken == "" {
			return h.reply(c).Fail(http.StatusServiceUnavailable,
				"cache purge is unavailable: COCKPIT_API_TOKEN is not configured", nil)
		}

		supplied := c.Request().Header.Get("X-Api-Key")

		if subtle.ConstantTimeCompare([]byte(supplied), []byte(h.Config.CockpitToken)) != 1 {
			return h.reply(c).Fail(http.StatusUnauthorized, "invalid token", nil)
		}
	}

	if err := h.Cache.Purge(c.Request().Context(), homeCacheKey); err != nil {
		return h.reply(c).Fail(http.StatusInternalServerError, "purge failed", err)
	}

	go h.warmHome()

	return h.reply(c).Text(http.StatusOK, "purged")
}

// warmHome re-renders the page in the background after a purge, so the next
// visitor finds a warm cache instead of paying for the cold path. Single-flight
// in the cache means concurrent purges - and any visitor who arrives mid-render
// - collapse into this one render rather than piling onto the CMS.
func (h *Handlers) warmHome() {
	if _, _, err := h.Cache.HTML(context.Background(), homeCacheKey, h.renderHome); err != nil {
		h.Log.Warn("cache re-warm failed", "key", homeCacheKey, "err", err)
	}
}
