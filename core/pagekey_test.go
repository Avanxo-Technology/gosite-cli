package gosite

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"testing/fstest"
)

func TestPageCacheKey(t *testing.T) {
	cases := []struct {
		uri       string
		want      string
		wantQuery bool
	}{
		// Without a query the name is the one it always was.
		{"/", "/", false},
		{"/productos", "/productos", false},
		{"/caf%C3%A9", "/caf%C3%A9", false},
		// Same parameters in another order, or another encoding: one key.
		{"/productos?precio=1&categoria=a", "/productos?categoria=a&precio=1", true},
		{"/productos?categoria=a&precio=1", "/productos?categoria=a&precio=1", true},
		{"/productos?f=a%2Cb", "/productos?f=a%2Cb", true},
		{"/productos?f=a,b", "/productos?f=a%2Cb", true},
		// Tracking parameters do not make a new page.
		{"/productos?utm_source=x&utm_medium=y", "/productos", false},
		{"/productos?gclid=1&fbclid=2&UTM_Campaign=z", "/productos", false},
		{"/productos?sort=asc&utm_source=x", "/productos?sort=asc", true},
		// A repeated parameter keeps its order.
		{"/p?tag=b&tag=a", "/p?tag=b&tag=a", true},
		// A query that cannot be decoded is kept as received.
		{"/p?a=%zz", "/p?a=%zz", true},
	}
	for _, tc := range cases {
		u, err := url.ParseRequestURI(tc.uri)
		if err != nil {
			t.Fatalf("%s: %v", tc.uri, err)
		}
		got, hasQuery := pageCacheKey(u)
		if got != tc.want || hasQuery != tc.wantQuery {
			t.Errorf("pageCacheKey(%q) = %q, %v; want %q, %v", tc.uri, got, hasQuery, tc.want, tc.wantQuery)
		}
	}
}

// Issue #55: a crawler walking query variants of one listing must not create a
// key per spelling, nor a 24-hour stale copy per variant.
func TestCachedRenderBoundsQueryVariants(t *testing.T) {
	t.Setenv("APP_ENV", "production") // development bypasses the cache
	theme := fstest.MapFS{
		"layout.html":          {Data: []byte(`{{define "layout"}}{{template "content" .}}{{end}}`)},
		"pages/productos.html": {Data: []byte(`{{define "content"}}` + strings.Repeat("<p>item</p>", 200) + `{{end}}`)},
	}
	var builds int
	base := &testSite{}
	base.routes = func(r Router) {
		r.GET("/productos", func(c *Context) error {
			return r.CachedRender(c, "productos", func(ctx context.Context) (Page, error) {
				builds++
				return Page{}, nil
			})
		})
	}
	s, mr := newTestServer(t, base, WithTheme(theme))

	for _, uri := range []string{
		"/productos?precio=1&categoria=a",
		"/productos?categoria=a&precio=1&utm_source=bot",
		"/productos?gclid=x&categoria=a&precio=1",
	} {
		if rec := do(t, s, http.MethodGet, uri, ""); rec.Code != http.StatusOK {
			t.Fatalf("%s: %d", uri, rec.Code)
		}
	}
	do(t, s, http.MethodGet, "/productos?utm_campaign=z", "")

	const prefix = "demo:production:cache:page:"
	if builds != 2 {
		t.Errorf("builds = %d, want 2 (one per distinct page)", builds)
	}
	want := map[string]bool{
		prefix + "/productos?categoria=a&precio=1": true,
		prefix + "/productos":                      true,
		prefix + "/productos:stale":                true, // only the bare URL
	}
	keys := mr.Keys()
	for _, k := range keys {
		if strings.HasPrefix(k, prefix) && !want[k] {
			t.Errorf("unexpected key %q", k)
		}
	}
	for k := range want {
		if !mr.Exists(k) {
			t.Errorf("missing key %q (have %v)", k, keys)
		}
	}
}
