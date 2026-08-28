package handlers

import (
	"context"
	"crypto/subtle"
	"encoding/json"
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

	ctx := c.Request().Context()

	model, id := purgeTarget(c)

	// Some content is not part of any one page: analytics keys and anything
	// else the layout carries are on all of them. Purging only the area an
	// edit "belongs" to would leave every other page serving the old value for
	// the rest of its cache window.
	if isSiteWide(model) {
		if err := h.Cache.PurgeAll(ctx, cacheKeyPrefix); err != nil {
			return h.reply(c).Fail(http.StatusInternalServerError, "purge failed", err)
		}
		go h.warmHome()
		return h.reply(c).Text(http.StatusOK, "purged")
	}

	if err := h.Cache.Purge(ctx, homeCacheKey); err != nil {
		return h.reply(c).Fail(http.StatusInternalServerError, "purge failed", err)
	}

	// Features owning their own keys invalidate them precisely. The body is
	// optional: the on-page button sends none, and so does a CMS older than
	// this app. Anything unreadable is treated as "not named" rather than as an
	// error - the home purge above already happened, and failing here would
	// report a purge that in fact took place.
	for _, hook := range h.purgeHooks {
		if err := hook(ctx, model, id); err != nil {
			return h.reply(c).Fail(http.StatusInternalServerError, "purge failed", err)
		}
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

// purgeTarget reads the optional {"model": "...", "id": "..."} body naming what
// the CMS changed. Missing, malformed or empty bodies yield two empty strings.
func purgeTarget(c *echo.Context) (model, id string) {
	body := c.Request().Body
	if body == nil {
		return "", ""
	}

	var payload struct {
		Model string `json:"model"`
		ID    string `json:"id"`
	}
	if err := json.NewDecoder(body).Decode(&payload); err != nil {
		return "", ""
	}
	return payload.Model, payload.ID
}

// siteWideModels are the collections whose content appears in the layout, and
// therefore on every page. A change to one of them invalidates everything.
var siteWideModels = map[string]bool{
	"analyticsIntegrations": true,
	// Webapp SEO configuration and per-page SEO overrides are rendered by the
	// layout on every page, so editing either invalidates the whole site.
	"webapp":   true,
	"seoPages": true,
}

func isSiteWide(model string) bool { return siteWideModels[model] }
