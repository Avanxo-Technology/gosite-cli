package gosite

import (
	"bytes"
	"context"
	"maps"
	"net/http"
	"time"
)

// Page is what every template a site renders through core receives. Its field
// names are the contract with templates: {{.Title}}, {{index .Content "hero"}}.
type Page struct {
	// Title is the fallback <title> when SEO resolves none.
	Title string

	// Path is the request path SEO resolves against. Render fills it from the
	// request when left empty.
	Path string

	// Content is the CMS content the page shows. Always a plain map - a
	// cms.Content assigns to it directly - so template helpers that expect
	// map[string]any never silently fall back on a named map type.
	Content map[string]any

	// SEOData overrides the resolved SEO for this page: title, description,
	// image, canonical, noIndex, type.
	SEOData map[string]any

	// Data holds the site's own values: what its TemplateDataer returns,
	// merged under anything set here.
	Data map[string]any

	// IsDev is true in development. Render fills it.
	IsDev bool
}

// render renders a page from the site's theme and writes it as HTML.
func (s *Server) render(c *Context, status int, name string, p Page) error {
	html, err := s.renderBytes(c, name, p)
	if err != nil {
		s.log.Error("render failed", "page", name, "err", err)
		return c.String(http.StatusInternalServerError, "render failed")
	}
	return c.HTMLBlob(status, html)
}

// cachedRender serves a page from the page cache, building it on a miss.
//
// The key is the request path and query under "<project>:cache:page:", which
// every purge clears, so an editor publishing reaches these pages without the
// site naming its keys. build runs with its own context, detached from the
// request: a cold render is shared by every visitor waiting on it, and one of
// them disconnecting must not cancel it for the rest. A failed build is never
// cached; a stale copy is served instead when there is one.
func (s *Server) cachedRender(c *Context, name string, build func(ctx context.Context) (Page, error)) error {
	key := s.core.Config.CacheKeyPrefix() + "page:" + c.Request().URL.RequestURI()
	html, cached, err := s.core.Handlers.Cache.HTML(c.Request().Context(), key, func() ([]byte, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		p, err := build(ctx)
		if err != nil {
			return nil, err
		}
		return s.renderBytes(c, name, p)
	})
	if err != nil {
		return s.core.Handlers.Reply(c).Fail(http.StatusBadGateway, "could not load the page", err)
	}
	return s.core.Handlers.Reply(c).Page(html, cached)
}

// renderBytes fills what Render owns in p and executes the page.
func (s *Server) renderBytes(c *Context, name string, p Page) ([]byte, error) {
	if p.Path == "" {
		p.Path = c.Request().URL.Path
	}
	if p.Content == nil {
		p.Content = map[string]any{}
	}
	if p.SEOData == nil {
		p.SEOData = map[string]any{}
	}
	data := map[string]any{}
	if s.templateData != nil {
		maps.Copy(data, s.templateData.TemplateData(c, name))
	}
	maps.Copy(data, p.Data)
	p.Data = data
	p.IsDev = s.core.Config.IsDev()

	// Rendered into a buffer first so a template error is a 500, not half a
	// page with a 200 status already sent.
	var buf bytes.Buffer
	if err := s.core.Renderer.Page(&buf, name, p); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
