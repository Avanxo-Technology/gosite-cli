package handlers

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/labstack/echo/v5"

	"__MODULE__/internal/cms"
)

// homeCacheKey is the Redis key holding the fully rendered home page.
const homeCacheKey = "__PROJECT__:home_html"

// Home serves the page through the cache.
//
// The cache-aside dance lives in cache.Cache.HTML; this handler only says what
// to render when the cache is cold. On a hit none of the closure runs, which
// is why a hit costs microseconds.
func (h *Handlers) Home(c *echo.Context) error {
	html, cached, err := h.Cache.HTML(c.Request().Context(), homeCacheKey, h.renderHome)

	// A "home" singleton nobody has created yet is not a broken site: the
	// template renders every block from its own fallback text, which is what
	// those fallbacks are for. Serving it uncached means the real content
	// appears the moment somebody creates the singleton, instead of after a
	// TTL. Any other failure is still a 502 - stale or missing CMS content
	// must not be cached and passed off as the page.
	if errors.Is(err, cms.ErrNotFound) {
		page, renderErr := h.renderHomeContent(cms.Content{})
		if renderErr != nil {
			return h.reply(c).Fail(http.StatusInternalServerError, "could not render the page", renderErr)
		}
		h.Log.Warn("no 'home' singleton in the CMS yet; serving the template fallbacks")
		return h.reply(c).Page(page, false)
	}

	if err != nil {
		return h.reply(c).Fail(http.StatusBadGateway, "could not load the page", err)
	}
	return h.reply(c).Page(html, cached)
}

// renderHome builds the page from scratch. It deliberately uses its own context
// rather than the request's: a cold render is shared by every request waiting
// on it, so if the one caller that happened to trigger it disconnects, that
// must not cancel the work everyone else is waiting for.
//
// The CMS client already retries once on transient failures. If both attempts
// fail the content will be empty and this method returns an error so the cache
// layer discards the render instead of poisoning the page for 10 minutes.
func (h *Handlers) renderHome() ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	content, err := h.CMS.SingletonErr(ctx, "home")
	if err != nil {
		// Passed up so the caller can tell "not created yet" from "the CMS is
		// down"; both stay out of the cache.
		return nil, err
	}

	// The CMS answered, and there is nothing in it. That is a singleton nobody
	// has filled in yet, not a broken site - and it is reported as such so the
	// caller serves the template's own fallbacks instead of a 502. Caching it
	// would be wrong either way: the render carries no CMS content, so image
	// src attributes come out empty and the page would stay that way for a
	// whole TTL after somebody finally writes the content.
	if len(content) == 0 {
		return nil, fmt.Errorf("%w: the home singleton is empty", cms.ErrNotFound)
	}

	return h.renderHomeContent(content)
}

// renderHomeContent turns CMS content into the page. Split out so the handler
// can render the fallback page directly, without going through the cache.
func (h *Handlers) renderHomeContent(content cms.Content) ([]byte, error) {
	var buf bytes.Buffer
	err := h.Renderer.Page(&buf, "home", map[string]any{
		"Title":   "__PROJECT__",
		"Path":    "/",
		"Content": content,
		"IsDev":   h.Config.IsDev(),
	})
	return buf.Bytes(), err
}
