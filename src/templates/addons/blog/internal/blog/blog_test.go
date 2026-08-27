package blog_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/labstack/echo/v5"

	"__MODULE__/internal/app"
	"__MODULE__/internal/blog"
	"__MODULE__/internal/config"
	"__MODULE__/internal/handlers"
)

// fakeCockpit serves the two collections the blog reads.
func fakeCockpit(t *testing.T, posts []map[string]any) *httptest.Server {
	t.Helper()
	blogs := []map[string]any{
		{"_id": "b1", "title": "Noticias", "slug": "noticias", "description": "Lo último"},
		{"_id": "b2", "title": "Casos", "slug": "casos"},
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		var filter map[string]any
		json.Unmarshal([]byte(q.Get("filter")), &filter)

		var source []map[string]any
		switch {
		case strings.HasSuffix(r.URL.Path, "/blogs"):
			source = blogs
		case strings.HasSuffix(r.URL.Path, "/blogPosts"):
			source = posts
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
				if k == "blog._id" {
					if b, isMap := item["blog"].(map[string]any); isMap {
						got = b["_id"]
					}
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
//	docker run -d --rm -p 63799:6379 redis:7-alpine
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
	a, err := app.NewApp(cfg, testLogger())
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	t.Cleanup(func() { a.Close() })

	// Start from an empty cache so one test cannot see another's pages. This
	// erases the database in REDIS_TEST_URL, which is why that variable has no
	// default.
	a.Redis.FlushDB(t.Context())

	return app.NewRouter(a)
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
