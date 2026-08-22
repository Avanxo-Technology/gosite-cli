package handlers

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/labstack/echo/v5"
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

	content := h.CMS.Singleton(ctx, "home")

	// Guard: if the CMS returned no content at all (unreachable, wrong
	// credentials, etc.) the templates render every text block from hardcoded
	// strings but all image src attributes become empty. Caching that HTML
	// poisons the page until the next TTL expiry, which is exactly the bug
	// users see. Return an error so the cache layer discards the render.
	if len(content) == 0 {
		return nil, fmt.Errorf("cockpit returned empty content for home singleton")
	}

	var buf bytes.Buffer
	err := h.Renderer.Page(&buf, "home", map[string]any{
		"Title":   "__PROJECT__",
		"Content": content,
		"IsDev":   h.Config.IsDev(),
	})
	return buf.Bytes(), err
}
