package gosite

import (
	"bytes"
	"maps"
	"net/http"
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
		s.log.Error("render failed", "page", name, "err", err)
		return c.String(http.StatusInternalServerError, "render failed")
	}
	return c.HTMLBlob(status, buf.Bytes())
}
