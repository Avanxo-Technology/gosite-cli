package blog_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/addon"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/addons/blog"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/app"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// fakeCockpit serves the two collections the blog reads and the webapp
// singleton SEO reads.
func fakeCockpit(t *testing.T, posts []map[string]any) *httptest.Server {
	t.Helper()
	blogs := []map[string]any{
		{"_id": "b1", "title": "Noticias", "slug": "noticias", "description": "Lo último"},
		{"_id": "b2", "title": "Casos", "slug": "casos"},
	}
	categories := []map[string]any{
		{"_id": "c1", "title": "Maquinaria", "slug": "maquinaria"},
		{"_id": "c2", "title": "Obras", "slug": "obras"},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		var filter map[string]any
		json.Unmarshal([]byte(q.Get("filter")), &filter)

		// The webapp singleton is where the site's public origin lives, and
		// canonical URLs are built from it.
		if strings.HasSuffix(r.URL.Path, "/webapp") {
			json.NewEncoder(w).Encode(map[string]any{"siteUrl": "https://example.com"})
			return
		}

		var source []map[string]any
		switch {
		case strings.HasSuffix(r.URL.Path, "/blogs"):
			source = blogs
		case strings.HasSuffix(r.URL.Path, "/blogPosts"):
			source = posts
		case strings.HasSuffix(r.URL.Path, "/blogCategories"):
			source = categories
		default:
			w.WriteHeader(404)
			return
		}

		matched := []map[string]any{}
		for _, item := range source {
			ok := true
			for k, v := range filter {
				if k == "_state" {
					continue
				}
				got := item[k]
				if ref, field, dotted := strings.Cut(k, "."); dotted {
					got = nil
					if b, isMap := item[ref].(map[string]any); isMap {
						got = b[field]
					}
				}
				if op, isOp := v.(map[string]any); isOp {
					if ne, has := op["$ne"]; has && fmt.Sprint(got) == fmt.Sprint(ne) {
						ok = false
						break
					}
					continue
				}
				if fmt.Sprint(got) != fmt.Sprint(v) {
					ok = false
					break
				}
			}
			if ok {
				matched = append(matched, item)
			}
		}

		// Sort like Cockpit for the one key the blog sorts by.
		var sortSpec map[string]int
		json.Unmarshal([]byte(q.Get("sort")), &sortSpec)
		if dir, ok := sortSpec["publishedAt"]; ok {
			sort.SliceStable(matched, func(i, j int) bool {
				a, b := fmt.Sprint(matched[i]["publishedAt"]), fmt.Sprint(matched[j]["publishedAt"])
				if dir < 0 {
					return a > b
				}
				return a < b
			})
		}

		skip, limit := 0, len(matched)
		fmt.Sscanf(q.Get("skip"), "%d", &skip)
		fmt.Sscanf(q.Get("limit"), "%d", &limit)
		total := len(matched)
		if skip > len(matched) {
			matched = nil
		} else {
			matched = matched[skip:]
		}
		if limit < len(matched) {
			matched = matched[:limit]
		}

		json.NewEncoder(w).Encode(map[string]any{
			"data": matched,
			"meta": map[string]any{"total": total},
		})
	}))
	t.Cleanup(srv.Close)
	return srv
}

const testToken = "test-token"

// These tests need a Redis they are allowed to erase, so they ask for one
// explicitly rather than defaulting to a reachable address. A default would
// eventually point at a real deployment's Redis, and the setup below flushes
// the database it connects to. Opt in with, for example:
//
//	docker run -d --rm -p 63799:6379 redis:7.4.12-alpine
//	REDIS_TEST_URL=redis://127.0.0.1:63799/9 go test ./...
func testRedisURL(t *testing.T) string {
	t.Helper()
	url := os.Getenv("REDIS_TEST_URL")
	if url == "" {
		t.Skip("REDIS_TEST_URL is not set; skipping blog tests that need Redis")
	}
	return url
}

func newApp(t *testing.T, posts []map[string]any) *echo.Echo {
	return newAppWithToken(t, posts, testToken)
}

func newAppWithToken(t *testing.T, posts []map[string]any, token string) *echo.Echo {
	t.Helper()
	cms := fakeCockpit(t, posts)

	cfg := config.Config{
		CockpitURL:   cms.URL,
		CockpitToken: token,
		RedisURL:     testRedisURL(t),
		Environment:  "production",
		SiteURL:      "https://example.com",
	}
	enabled, err := addon.Resolve([]string{"Blog"})
	if err != nil {
		t.Fatal(err)
	}
	a, err := app.NewApp(cfg, testLogger(), views.WithPages(enabled[0].Pages))
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	t.Cleanup(func() { a.Close() })

	// Start from an empty cache so one test cannot see another's pages. This
	// erases the database in REDIS_TEST_URL, which is why that variable has no
	// default.
	a.Redis.FlushDB(t.Context())

	return app.NewRouter(a, app.RouterOptions{Mounts: []func(*echo.Echo, *handlers.Handlers){enabled[0].Mount}})
}

func get(t *testing.T, e *echo.Echo, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func samplePosts() []map[string]any {
	posts := []map[string]any{}
	for i := 1; i <= 12; i++ {
		posts = append(posts, map[string]any{
			"_id":         fmt.Sprintf("p%d", i),
			"title":       fmt.Sprintf("Post %d", i),
			"slug":        fmt.Sprintf("post-%d", i),
			"excerpt":     "resumen",
			"body":        "<p>cuerpo</p>",
			"publishedAt": "2026-08-01",
			"blog":        map[string]any{"_id": "b1", "slug": "noticias"},
		})
	}
	// Same slug in a different blog: both must resolve to their own article.
	posts = append(posts, map[string]any{
		"_id": "x1", "title": "Novedades de Casos", "slug": "novedades",
		"blog": map[string]any{"_id": "b2", "slug": "casos"},
	})
	posts = append(posts, map[string]any{
		"_id": "x2", "title": "Novedades de Noticias", "slug": "novedades",
		"blog": map[string]any{"_id": "b1", "slug": "noticias"},
	})
	return posts
}

func TestIndexAndArticle(t *testing.T) {
	e := newApp(t, samplePosts())

	rec := get(t, e, "/noticias")
	if rec.Code != 200 {
		t.Fatalf("/noticias = %d", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), "Noticias") {
		t.Error("index does not name the blog")
	}

	rec = get(t, e, "/noticias/post-1")
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), "Post 1") {
		t.Fatalf("article = %d, body missing title", rec.Code)
	}
}

func TestSameSlugInTwoBlogs(t *testing.T) {
	e := newApp(t, samplePosts())

	a := get(t, e, "/noticias/novedades").Body.String()
	b := get(t, e, "/casos/novedades").Body.String()

	if !strings.Contains(a, "Novedades de Noticias") {
		t.Error("/noticias/novedades served the wrong article")
	}
	if !strings.Contains(b, "Novedades de Casos") {
		t.Error("/casos/novedades served the wrong article")
	}
}

func TestNotFound(t *testing.T) {
	e := newApp(t, samplePosts())

	for _, path := range []string{"/no-existe", "/noticias/no-existe", "/noticias?page=99", "/noticias?page=0", "/noticias?page=abc"} {
		if code := get(t, e, path).Code; code != http.StatusNotFound {
			t.Errorf("%s = %d, want 404", path, code)
		}
	}
}

func TestPagination(t *testing.T) {
	e := newApp(t, samplePosts())

	first := get(t, e, "/noticias").Body.String()
	if !strings.Contains(first, "Older") {
		t.Error("first page offers no next link with 13 posts")
	}
	if strings.Contains(first, "Newer") {
		t.Error("first page offers a previous link")
	}

	last := get(t, e, "/noticias?page=2").Body.String()
	if strings.Contains(last, "Older") {
		t.Error("last page still offers a next link")
	}
	if !strings.Contains(last, "Newer") {
		t.Error("second page offers no previous link")
	}
}

func TestSEOTags(t *testing.T) {
	e := newApp(t, samplePosts())

	body := get(t, e, "/noticias/post-1").Body.String()
	for _, want := range []string{
		`<link rel="canonical" href="https://example.com/noticias/post-1">`,
		`<meta property="og:title" content="Post 1">`,
		`<meta name="description" content="resumen">`,
	} {
		if !strings.Contains(body, want) {
			t.Errorf("missing %s", want)
		}
	}
	// No cover image on these posts: the tag must be absent, not empty.
	if strings.Contains(body, "og:image") {
		t.Error("og:image emitted for an article with no cover")
	}
}

func TestBlogNeverShadowsTheRestOfTheSite(t *testing.T) {
	e := newApp(t, samplePosts())

	if code := get(t, e, "/healthz").Code; code == http.StatusNotFound {
		t.Error("/healthz was swallowed by the blog route")
	}
	if code := get(t, e, "/").Code; code == http.StatusNotFound {
		t.Error("/ was swallowed by the blog route")
	}
}

func TestCacheHitOnSecondRequest(t *testing.T) {
	e := newApp(t, samplePosts())

	if h := get(t, e, "/noticias/post-1").Header().Get("X-Cache"); h != "MISS" {
		t.Errorf("first request X-Cache = %q, want MISS", h)
	}
	if h := get(t, e, "/noticias/post-1").Header().Get("X-Cache"); h != "HIT" {
		t.Errorf("second request X-Cache = %q, want HIT", h)
	}
}

var _ = blog.Mount
var _ = handlers.New

// A page the project adds later must win over a blog that happens to share its
// slug - registered after the blog's :blog route, which is the harder order.
func TestProjectPageWinsOverABlogSlug(t *testing.T) {
	e := newApp(t, samplePosts())

	e.GET("/noticias", func(c *echo.Context) error {
		return c.String(http.StatusOK, "THE PROJECT PAGE")
	})

	rec := get(t, e, "/noticias")
	if !strings.Contains(rec.Body.String(), "THE PROJECT PAGE") {
		t.Errorf("the blog shadowed the project's own page: %.80s", rec.Body.String())
	}
}

// categorizedPosts: five articles in "maquinaria" (newest last), one in
// "obras", one without a category.
func categorizedPosts() []map[string]any {
	maq := map[string]any{"_id": "c1", "title": "Maquinaria", "slug": "maquinaria"}
	posts := []map[string]any{}
	for i := 1; i <= 5; i++ {
		posts = append(posts, map[string]any{
			"_id": fmt.Sprintf("m%d", i), "title": fmt.Sprintf("Maq %d", i), "slug": fmt.Sprintf("maq-%d", i),
			"body": "<p>" + strings.Repeat("palabra ", 450) + "</p>", "publishedAt": fmt.Sprintf("2026-08-0%d", i),
			"_modified": float64(1790000000 + i),
			"blog":      map[string]any{"_id": "b1", "slug": "noticias"}, "category": maq,
		})
	}
	posts = append(posts,
		map[string]any{"_id": "o1", "title": "Obra 1", "slug": "obra-1", "body": "<p>corto</p>",
			"blog": map[string]any{"_id": "b1", "slug": "noticias"}, "category": map[string]any{"_id": "c2", "title": "Obras", "slug": "obras"}},
		map[string]any{"_id": "s1", "title": "Suelto", "slug": "suelto", "body": "<p>sin categoría</p>",
			"blog": map[string]any{"_id": "b1", "slug": "noticias"}},
		map[string]any{"_id": "h1", "title": "Oculto", "slug": "oculto", "body": "<p>noindex</p>", "seoNoIndex": true,
			"blog": map[string]any{"_id": "b1", "slug": "noticias"}},
	)
	return posts
}

func TestCategoryPage(t *testing.T) {
	e := newApp(t, categorizedPosts())

	rec := get(t, e, "/noticias/category/maquinaria")
	if rec.Code != 200 {
		t.Fatalf("category page = %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Maq 1") || strings.Contains(body, "Obra 1") || strings.Contains(body, "Suelto") {
		t.Errorf("category page must list only its articles:\n%s", body)
	}
	if !strings.Contains(body, "Maquinaria | Noticias") {
		t.Error("the title does not name the category")
	}
	if code := get(t, e, "/noticias/category/no-existe").Code; code != 404 {
		t.Errorf("unknown category = %d, want 404", code)
	}
	if code := get(t, e, "/no-existe/category/maquinaria").Code; code != 404 {
		t.Errorf("unknown blog = %d, want 404", code)
	}
}

func TestTrailingSlashServesTheSamePage(t *testing.T) {
	e := newApp(t, categorizedPosts())
	for _, path := range []string{"/noticias", "/noticias/maq-1", "/noticias/category/maquinaria"} {
		plain, slashed := get(t, e, path), get(t, e, path+"/")
		if plain.Code != 200 || slashed.Code != 200 || plain.Body.String() != slashed.Body.String() {
			t.Errorf("%s = %d, %s/ = %d; want both 200 with the same body", path, plain.Code, path, slashed.Code)
		}
	}
}

func TestArticleReadingTimeAndRelated(t *testing.T) {
	e := newApp(t, categorizedPosts())

	body := get(t, e, "/noticias/maq-1").Body.String()
	// 450 words at 200 per minute, rounded up.
	if !strings.Contains(body, "3 min de lectura") {
		t.Errorf("reading time missing:\n%s", body)
	}
	related := body[strings.Index(body, "Artículos relacionados"):]
	for _, want := range []string{"Maq 5", "Maq 4", "Maq 3"} {
		if !strings.Contains(related, want) {
			t.Errorf("related lacks %s", want)
		}
	}
	if strings.Contains(related, "Maq 2") || strings.Contains(related, ">Maq 1<") || strings.Contains(related, "Obra 1") {
		t.Errorf("related must be the 3 newest of the same category, without the article:\n%s", related)
	}
	if !strings.Contains(body, `href="/noticias/category/maquinaria"`) {
		t.Error("the category does not link to its page")
	}

	body = get(t, e, "/noticias/suelto").Body.String()
	if strings.Contains(body, "Artículos relacionados") || !strings.Contains(body, "1 min de lectura") {
		t.Errorf("an article without category has no related list and at least 1 minute:\n%s", body)
	}
}

func TestBlogInSitemap(t *testing.T) {
	e := newApp(t, categorizedPosts())
	body := get(t, e, "/sitemap.xml").Body.String()
	for _, want := range []string{
		"<loc>https://example.com/noticias</loc>",
		"<loc>https://example.com/casos</loc>",
		"<loc>https://example.com/noticias/maq-3</loc>\n    <lastmod>2026-09-21T14:13:23Z</lastmod>",
		"<loc>https://example.com/noticias/suelto</loc>",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("sitemap lacks %q:\n%s", want, body)
		}
	}
	if strings.Contains(body, "/noticias/oculto") {
		t.Error("an article marked seoNoIndex is in the sitemap")
	}
}

func TestBlogPagesCarrySiteData(t *testing.T) {
	cms := fakeCockpit(t, categorizedPosts())
	cfg := config.Config{CockpitURL: cms.URL, CockpitToken: testToken, RedisURL: testRedisURL(t), Environment: "production", SiteURL: "https://example.com"}
	enabled, err := addon.Resolve([]string{"Blog"})
	if err != nil {
		t.Fatal(err)
	}
	theme := fstest.MapFS{
		"layout.html":     {Data: []byte(`{{define "layout"}}{{template "content" .}}{{end}}`)},
		"pages/home.html": {Data: []byte(`{{define "content"}}home{{end}}`)},
		// The cache refuses pages under 1 KB, so the page carries padding
		// (visible text: html/template drops comments).
		"pages/blog-index.html": {Data: []byte(`{{define "content"}}[{{.Header}}|{{.Title}}]<p>` + strings.Repeat("x", 1100) + `</p>{{end}}`)},
	}
	a, err := app.NewApp(cfg, testLogger(), views.WithPages(enabled[0].Pages), views.WithTheme(theme))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close() })
	a.Redis.FlushDB(t.Context())
	a.Handlers.SetSiteData(func(_ *echo.Context, page string) map[string]any {
		// Title collides with the blog's own key: the blog's must win.
		return map[string]any{"Header": "site header for " + page, "Title": "site title"}
	})
	e := app.NewRouter(a, app.RouterOptions{Mounts: []func(*echo.Echo, *handlers.Handlers){enabled[0].Mount}})

	body, _, _ := strings.Cut(get(t, e, "/noticias").Body.String(), "<p>")
	if body != "[site header for blog-index|Noticias]" {
		t.Errorf("body = %q, want the site's Header and the blog's Title", body)
	}
}
