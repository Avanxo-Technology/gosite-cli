package handlers

import (
	"context"
	"encoding/xml"
	"net/http"
	"strings"
	"time"

	"github.com/labstack/echo/v5"

	"__MODULE__/internal/seo"
)

// SitemapProvider contributes paths owned by a feature that mounts its own
// pages. The blog registers one so its posts appear without this package
// having to know the blog exists - the same arrangement as OnPurge.
type SitemapProvider func(ctx context.Context) []seo.SitemapEntry

// OnSitemap registers a source of extra sitemap paths. Call during mount,
// before the server starts serving.
func (h *Handlers) OnSitemap(provider SitemapProvider) {
	h.sitemapProviders = append(h.sitemapProviders, provider)
}

type urlEntry struct {
	Loc     string `xml:"loc"`
	LastMod string `xml:"lastmod,omitempty"`
}

type urlSet struct {
	XMLName xml.Name   `xml:"urlset"`
	NS      string     `xml:"xmlns,attr"`
	URLs    []urlEntry `xml:"url"`
}

// Sitemap serves /sitemap.xml, built at request time from the seoPages
// collection plus whatever the mounted features contribute.
//
// Returns 404 when the webapp singleton has no Site URL: a sitemap has to
// carry absolute URLs, and inventing an origin from the request host would
// publish the wrong one behind a proxy or on a preview domain.
func (h *Handlers) Sitemap(c *echo.Context) error {
	if h.SEO == nil {
		return (*c).NoContent(http.StatusNotFound)
	}

	base := strings.TrimRight(h.SEO.SiteURL(), "/")
	if base == "" {
		return (*c).NoContent(http.StatusNotFound)
	}

	ctx := (*c).Request().Context()

	entries := append([]seo.SitemapEntry{{Path: "/"}}, h.SEO.SitemapPaths(ctx)...)
	for _, provider := range h.sitemapProviders {
		entries = append(entries, provider(ctx)...)
	}

	seen := make(map[string]bool, len(entries))
	set := urlSet{NS: "http://www.sitemaps.org/schemas/sitemap/0.9"}

	for _, entry := range entries {
		loc := base + "/" + strings.TrimLeft(entry.Path, "/")
		if seen[loc] {
			continue
		}
		seen[loc] = true

		url := urlEntry{Loc: loc}
		if !entry.LastMod.IsZero() {
			url.LastMod = entry.LastMod.UTC().Format(time.RFC3339)
		}
		set.URLs = append(set.URLs, url)
	}

	body, err := xml.MarshalIndent(set, "", "  ")
	if err != nil {
		return err
	}

	return (*c).Blob(http.StatusOK, "application/xml; charset=utf-8",
		append([]byte(xml.Header), body...))
}
