package views

import (
	"bytes"
	"testing"
)

// Renders pages through the real layout to catch template errors the compiler
// cannot see: the SEO function wired into the layout, the favicon helper and
// the resolved title must appear on every page.
func TestBootRender(t *testing.T) {
	r := NewRenderer("http://assets.local",
		WithSEO(func(path string, overrides ...any) map[string]any {
			return map[string]any{
				"title":       "Resolved Title",
				"description": "Resolved description",
				"image":       "http://assets.local/og.webp",
				"canonical":   "https://example.com" + path,
				"jsonLd":      `{"@context":"https://schema.org"}`,
				"siteName":    "Analytics Draft",
			}
		}),
		WithFavicon(func() string { return "http://assets.local/favicon.svg" }),
	)

	probe := map[string]any{
		"Title":   "Fallback Title",
		"Content": map[string]any{},
		"IsDev":   true,
		"Path":    "/",
		"SEOData": map[string]any{},
		"Blog":    map[string]any{},
		"Post":    map[string]any{},
		"Posts":   []map[string]any{},
		"Author":  map[string]any{},
		"Meta":    map[string]any{},
		"Page":    1,
		"HasMore": false,
		"PrevURL": "",
		"NextURL": "",
		"Total":   0,
	}

	for page := range r.pages {
		var buf bytes.Buffer
		if err := r.Page(&buf, page, probe); err != nil {
			t.Fatalf("page %q failed: %v", page, err)
		}
		if !bytes.Contains(buf.Bytes(), []byte(`<title>Resolved Title</title>`)) {
			t.Errorf("page %q: resolved title missing", page)
		}
		if !bytes.Contains(buf.Bytes(), []byte(`og:title`)) {
			t.Errorf("page %q: og:title missing", page)
		}
		if !bytes.Contains(buf.Bytes(), []byte(`og:site_name`)) {
			t.Errorf("page %q: og:site_name missing", page)
		}
		if !bytes.Contains(buf.Bytes(), []byte(`rel="icon"`)) {
			t.Errorf("page %q: favicon missing", page)
		}
	}
}

// A page that passes no Path and no SEOData must still render with webapp
// defaults rather than erroring on the missing map keys.
func TestRenderWithoutPath(t *testing.T) {
	r := NewRenderer("http://assets.local",
		WithSEO(func(path string, overrides ...any) map[string]any {
			return map[string]any{"title": "Default Title"}
		}),
	)

	var buf bytes.Buffer
	err := r.Page(&buf, "home", map[string]any{
		"Title":   "Fallback",
		"Content": map[string]any{},
		"IsDev":   true,
	})
	if err != nil {
		t.Fatalf("render without Path failed: %v", err)
	}
	if !bytes.Contains(buf.Bytes(), []byte(`<title>Default Title</title>`)) {
		t.Errorf("default SEO title missing")
	}
}

// A nil resolver (a project where the SEO package was never wired) must render
// no tags and must not panic.
func TestRenderWithoutResolver(t *testing.T) {
	r := NewRenderer("http://assets.local")

	var buf bytes.Buffer
	err := r.Page(&buf, "home", map[string]any{
		"Title":   "Plain",
		"Content": map[string]any{},
		"IsDev":   true,
	})
	if err != nil {
		t.Fatalf("render without resolver failed: %v", err)
	}
	if !bytes.Contains(buf.Bytes(), []byte(`<title>Plain</title>`)) {
		t.Errorf("title fallback missing")
	}
}
