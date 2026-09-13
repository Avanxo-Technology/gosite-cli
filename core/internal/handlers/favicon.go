package handlers

import (
	"net/http"
	"strings"

	"github.com/labstack/echo/v5"
)

// Favicon serves /favicon.ico by redirecting to the favicon asset URL.
func (h *Handlers) Favicon(c *echo.Context) error {
	if h.SEO == nil {
		return (*c).NoContent(http.StatusNotFound)
	}

	config := h.SEO.GetWebappConfig()
	if config == nil || config.Favicon == "" {
		return (*c).NoContent(http.StatusNotFound)
	}

	// seo.assetURL already joined the asset base, so this is absolute for S3
	// storage. With local storage it is a site-root path ("/storage/uploads/..")
	// which only needs SiteURL to become absolute.
	url := config.Favicon
	if h.Config.SiteURL != "" && strings.HasPrefix(url, "/") {
		url = strings.TrimRight(h.Config.SiteURL, "/") + url
	}

	return (*c).Redirect(http.StatusMovedPermanently, url)
}
