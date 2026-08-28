package seo

import (
	"encoding/json"
	"testing"
)

func TestMergeOverridesNonEmptyOnly(t *testing.T) {
	base := &Data{Title: "Base", Description: "Base desc", Image: "base.webp"}
	over := &Data{Title: "Override", Description: ""}

	got := merge(base, over)

	if got.Title != "Override" {
		t.Errorf("title: want Override, got %q", got.Title)
	}
	if got.Description != "Base desc" {
		t.Errorf("empty override must not clobber base: got %q", got.Description)
	}
	if got.Image != "base.webp" {
		t.Errorf("image: want base.webp, got %q", got.Image)
	}
	// base must be untouched (merge returns a copy)
	if base.Title != "Base" {
		t.Errorf("merge mutated base: %q", base.Title)
	}
}

func TestMergeNoIndex(t *testing.T) {
	got := merge(&Data{}, &Data{NoIndex: true})
	if !got.NoIndex {
		t.Error("noIndex override must propagate")
	}
	// false cannot override true is fine - NoIndex defaults false either way,
	// but an explicit false override must not clear a true from base... or
	// must it? Today merge() only sets true; document the behaviour.
	got = merge(&Data{NoIndex: true}, &Data{NoIndex: false})
	if !got.NoIndex {
		t.Error("merge() never clears NoIndex - a per-page override cannot un-hide what a lower layer hid")
	}
}

func TestFromMapIgnoresUnknownKeys(t *testing.T) {
	d := FromMap(map[string]any{
		"title":    "T",
		"noIndex":  true,
		"nonsense": "ignored",
	})
	if d.Title != "T" || !d.NoIndex {
		t.Errorf("FromMap mismatch: %+v", d)
	}
}

func TestFromMapNil(t *testing.T) {
	if FromMap(nil) != nil {
		t.Error("FromMap(nil) must be nil so Resolve skips it")
	}
}

func TestToMapRoundTrip(t *testing.T) {
	d := &Data{Title: "T", Canonical: "https://x.co/a"}
	m := ToMap(d)
	if m["title"] != "T" || m["canonical"] != "https://x.co/a" {
		t.Errorf("ToMap mismatch: %+v", m)
	}
	if ToMap(nil) != nil {
		t.Error("ToMap(nil) must be nil")
	}
}

func TestFromBlogPostFallbacks(t *testing.T) {
	post := map[string]any{
		"title":   "Post Title",
		"excerpt": "Post excerpt",
		"cover":   map[string]any{"path": "2026/01/cover.webp"},
	}
	d := FromBlogPost(post)

	if d.Title != "Post Title" {
		t.Errorf("title should fall back to post title, got %q", d.Title)
	}
	if d.Description != "Post excerpt" {
		t.Errorf("description should fall back to excerpt, got %q", d.Description)
	}
	if d.Image != "2026/01/cover.webp" {
		t.Errorf("image should fall back to cover path, got %q", d.Image)
	}
}

func TestFromBlogPostOverridesWin(t *testing.T) {
	post := map[string]any{
		"title":          "Post Title",
		"seoTitle":       "SEO Title",
		"seoDescription": "SEO Desc",
		"seoNoIndex":     true,
	}
	d := FromBlogPost(post)

	if d.Title != "SEO Title" {
		t.Errorf("seoTitle must win over title, got %q", d.Title)
	}
	if d.Description != "SEO Desc" {
		t.Errorf("seoDescription must win, got %q", d.Description)
	}
	if !d.NoIndex {
		t.Error("seoNoIndex must propagate")
	}
}

func TestFromBlogPostNil(t *testing.T) {
	if FromBlogPost(nil) != nil {
		t.Error("FromBlogPost(nil) must be nil")
	}
}

func TestAssetPathShapes(t *testing.T) {
	if got := assetPath(map[string]any{"path": "a/b.webp"}); got != "a/b.webp" {
		t.Errorf("asset object: got %q", got)
	}
	if got := assetPath("a/b.webp"); got != "" {
		t.Errorf("bare string is not an asset object: got %q", got)
	}
	if got := assetPath(nil); got != "" {
		t.Errorf("nil: got %q", got)
	}
}

// A Cockpit asset path has no leading slash and is relative to the uploads
// root, so joining it must not depend on one. Emitting the bare path used to
// produce a relative URL that 404'd against the page's own origin.
func TestAssetURL(t *testing.T) {
	cases := []struct {
		name string
		base string
		path string
		want string
	}{
		{"s3 base, no leading slash", "https://assets.example.com", "2026/08/28/a.png", "https://assets.example.com/2026/08/28/a.png"},
		{"trailing slash on base", "https://assets.example.com/", "2026/08/28/a.png", "https://assets.example.com/2026/08/28/a.png"},
		{"leading slash on path", "https://assets.example.com", "/2026/08/28/a.png", "https://assets.example.com/2026/08/28/a.png"},
		{"local mount", "/storage/uploads", "2026/08/28/a.png", "/storage/uploads/2026/08/28/a.png"},
		{"no base falls back to site root", "", "2026/08/28/a.png", "/2026/08/28/a.png"},
		{"already absolute is left alone", "https://assets.example.com", "https://cdn.example/a.png", "https://cdn.example/a.png"},
		{"protocol-relative is left alone", "https://assets.example.com", "//cdn.example/a.png", "//cdn.example/a.png"},
		{"empty path stays empty", "https://assets.example.com", "", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := &SEO{assetBase: tc.base}
			if got := s.assetURL(tc.path); got != tc.want {
				t.Errorf("assetURL(%q) with base %q = %q, want %q", tc.path, tc.base, got, tc.want)
			}
		})
	}
}

// Canonical comes from the Site URL the singleton declares, never from the
// request, so a proxy or preview domain cannot publish the wrong origin.
func TestCanonicalURL(t *testing.T) {
	cases := []struct {
		name    string
		siteURL string
		path    string
		want    string
	}{
		{"home", "https://example.com", "/", "https://example.com/"},
		{"page", "https://example.com", "/about", "https://example.com/about"},
		{"trailing slash on origin", "https://example.com/", "/about", "https://example.com/about"},
		{"path without leading slash", "https://example.com", "about", "https://example.com/about"},
		{"empty path is the home page", "https://example.com", "", "https://example.com/"},
		{"no site url means no canonical", "", "/about", ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := canonicalURL(tc.siteURL, tc.path); got != tc.want {
				t.Errorf("canonicalURL(%q, %q) = %q, want %q", tc.siteURL, tc.path, got, tc.want)
			}
		})
	}
}

func TestDefaultJSONLD(t *testing.T) {
	t.Run("the singleton's own JSON-LD wins", func(t *testing.T) {
		config := &WebappConfig{JSONLD: `{"@type":"Custom"}`, SiteName: "Example"}
		if got := defaultJSONLD(config); got != `{"@type":"Custom"}` {
			t.Errorf("got %q", got)
		}
	})

	t.Run("no site name means no block", func(t *testing.T) {
		if got := defaultJSONLD(&WebappConfig{SiteURL: "https://example.com"}); got != "" {
			t.Errorf("a WebSite node with no name is useless, got %q", got)
		}
	})

	t.Run("built from the defaults", func(t *testing.T) {
		config := &WebappConfig{
			SiteName:           "Example",
			SiteURL:            "https://example.com",
			DefaultDescription: "A site",
			DefaultImage:       "https://cdn.example/a.png",
		}

		var node map[string]any
		if err := json.Unmarshal([]byte(defaultJSONLD(config)), &node); err != nil {
			t.Fatalf("output must be valid JSON: %v", err)
		}

		for key, want := range map[string]string{
			"@context":    "https://schema.org",
			"@type":       "WebSite",
			"name":        "Example",
			"url":         "https://example.com",
			"description": "A site",
			"image":       "https://cdn.example/a.png",
		} {
			if got, _ := node[key].(string); got != want {
				t.Errorf("%s = %q, want %q", key, got, want)
			}
		}
	})

	t.Run("optional fields are omitted, not empty", func(t *testing.T) {
		var node map[string]any
		json.Unmarshal([]byte(defaultJSONLD(&WebappConfig{SiteName: "Example"})), &node)

		for _, key := range []string{"url", "description", "image"} {
			if _, present := node[key]; present {
				t.Errorf("%s must be absent when unset", key)
			}
		}
	})

	t.Run("publisher becomes a nested Organization", func(t *testing.T) {
		config := &WebappConfig{
			SiteName:      "Example",
			Publisher:     "Acme Inc",
			PublisherLogo: "https://cdn.example/logo.png",
		}

		var node map[string]any
		if err := json.Unmarshal([]byte(defaultJSONLD(config)), &node); err != nil {
			t.Fatalf("output must be valid JSON: %v", err)
		}

		publisher, ok := node["publisher"].(map[string]any)
		if !ok {
			t.Fatalf("publisher must be an object, got %#v", node["publisher"])
		}
		if publisher["@type"] != "Organization" || publisher["name"] != "Acme Inc" {
			t.Errorf("publisher = %#v", publisher)
		}

		logo, ok := publisher["logo"].(map[string]any)
		if !ok {
			t.Fatalf("logo must be an ImageObject, got %#v", publisher["logo"])
		}
		if logo["@type"] != "ImageObject" || logo["url"] != "https://cdn.example/logo.png" {
			t.Errorf("logo = %#v", logo)
		}
	})

	t.Run("publisher without a logo omits the logo node", func(t *testing.T) {
		var node map[string]any
		json.Unmarshal([]byte(defaultJSONLD(&WebappConfig{SiteName: "Example", Publisher: "Acme Inc"})), &node)

		publisher, _ := node["publisher"].(map[string]any)
		if _, present := publisher["logo"]; present {
			t.Error("logo must be absent when unset")
		}
	})

	t.Run("nil config", func(t *testing.T) {
		if got := defaultJSONLD(nil); got != "" {
			t.Errorf("got %q", got)
		}
	})
}

func TestLangAndHandleNormalisation(t *testing.T) {
	if got := lang(""); got != "en" {
		t.Errorf("empty language must still declare one, got %q", got)
	}
	if got := lang("  es-ES  "); got != "es-ES" {
		t.Errorf("got %q", got)
	}
	if got := ogLocale("es-ES"); got != "es_ES" {
		t.Errorf("Open Graph wants underscores, got %q", got)
	}
	for _, in := range []string{"guarapodev", "@guarapodev", "  @guarapodev "} {
		if got := twitterHandle(in); got != "@guarapodev" {
			t.Errorf("twitterHandle(%q) = %q", in, got)
		}
	}
	if got := twitterHandle(""); got != "" {
		t.Errorf("empty handle must stay empty, got %q", got)
	}
}

// A blog post declares og:type "article"; without this the layout falls back to
// "website" and every post advertises itself as the site's front page.
func TestMergeCarriesType(t *testing.T) {
	got := merge(&Data{Type: "website"}, &Data{Type: "article"})
	if got.Type != "article" {
		t.Errorf("type: want article, got %q", got.Type)
	}
	if got := merge(&Data{Type: "website"}, &Data{}); got.Type != "website" {
		t.Errorf("an override with no type must not clear it, got %q", got.Type)
	}
}
