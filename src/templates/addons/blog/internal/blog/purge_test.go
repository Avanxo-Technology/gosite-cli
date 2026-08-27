package blog_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/labstack/echo/v5"
	"github.com/redis/go-redis/v9"
)

// redisForTest opens a second connection to the same database the app under
// test uses, so a test can inspect keys the app never touches.
func redisForTest(t *testing.T) *redis.Client {
	t.Helper()
	opts, err := redis.ParseURL(os.Getenv("REDIS_TEST_URL"))
	if err != nil {
		t.Fatal(err)
	}
	c := redis.NewClient(opts)
	t.Cleanup(func() { c.Close() })
	return c
}

func post(t *testing.T, e *echo.Echo, path, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Api-Key", testToken)
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, req)
	return rec
}

// Publishing an article must drop its page and its blog's index, and must not
// drop another blog's pages.
func TestPurgeIsScopedToTheChangedBlog(t *testing.T) {
	e := newApp(t, samplePosts())

	// Warm three pages across two blogs.
	get(t, e, "/noticias/post-1")
	get(t, e, "/noticias")
	get(t, e, "/casos/novedades")

	if h := get(t, e, "/casos/novedades").Header().Get("X-Cache"); h != "HIT" {
		t.Fatalf("setup: casos page not cached (%s)", h)
	}

	rec := post(t, e, "/cache/purge", `{"model":"blogPosts","id":"p1"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("purge = %d: %s", rec.Code, rec.Body.String())
	}

	if h := get(t, e, "/noticias/post-1").Header().Get("X-Cache"); h != "MISS" {
		t.Errorf("purged article still cached (%s)", h)
	}
	if h := get(t, e, "/noticias").Header().Get("X-Cache"); h != "MISS" {
		t.Errorf("index of the changed blog still cached (%s)", h)
	}
	if h := get(t, e, "/casos/novedades").Header().Get("X-Cache"); h != "HIT" {
		t.Errorf("another blog was purged too (%s)", h)
	}
}

// A purge naming nothing - the on-page button, or an older CMS - is the safe
// reading of "purge": every blog page goes.
func TestPurgeWithoutABodyDropsEveryBlogPage(t *testing.T) {
	e := newApp(t, samplePosts())

	get(t, e, "/noticias/post-1")
	get(t, e, "/casos/novedades")

	if rec := post(t, e, "/cache/purge", ""); rec.Code != http.StatusOK {
		t.Fatalf("purge = %d", rec.Code)
	}

	for _, path := range []string{"/noticias/post-1", "/casos/novedades"} {
		if h := get(t, e, path).Header().Get("X-Cache"); h != "MISS" {
			t.Errorf("%s survived a blanket purge (%s)", path, h)
		}
	}
}

// An unrelated model must not cost the blog its cache.
func TestPurgeOfAnUnrelatedModelLeavesTheBlogAlone(t *testing.T) {
	e := newApp(t, samplePosts())

	get(t, e, "/noticias/post-1")

	if rec := post(t, e, "/cache/purge", `{"model":"formSubmissions","id":"s1"}`); rec.Code != http.StatusOK {
		t.Fatalf("purge = %d", rec.Code)
	}
	if h := get(t, e, "/noticias/post-1").Header().Get("X-Cache"); h != "HIT" {
		t.Errorf("a form submission purged the blog (%s)", h)
	}
}

// Purging is authenticated and fail-closed outside development: v0.43.0 closed
// this hole and the blog must not reopen it.
func TestPurgeStaysFailClosed(t *testing.T) {
	e := newAppWithToken(t, samplePosts(), "") // production, no token configured

	rec := post(t, e, "/cache/purge", `{"model":"blogPosts","id":"p1"}`)
	if rec.Code != http.StatusServiceUnavailable {
		t.Errorf("purge without a configured token = %d, want 503", rec.Code)
	}
}

// Content the layout carries - analytics keys - is on every page, so changing
// it has to drop every page, not just the area it "belongs" to.
func TestSiteWideChangePurgesEveryPage(t *testing.T) {
	e := newApp(t, samplePosts())

	get(t, e, "/noticias/post-1")
	get(t, e, "/noticias")
	get(t, e, "/")

	if h := get(t, e, "/noticias/post-1").Header().Get("X-Cache"); h != "HIT" {
		t.Fatalf("setup: blog page not cached (%s)", h)
	}

	if rec := post(t, e, "/cache/purge", `{"model":"analyticsIntegrations","id":"a1"}`); rec.Code != http.StatusOK {
		t.Fatalf("purge = %d: %s", rec.Code, rec.Body.String())
	}

	for _, path := range []string{"/noticias/post-1", "/noticias"} {
		if h := get(t, e, path).Header().Get("X-Cache"); h != "MISS" {
			t.Errorf("%s still cached after a site-wide change (%s)", path, h)
		}
	}
}

// A site-wide purge is not a cache flush: several projects share one Redis.
func TestSiteWidePurgeLeavesOtherProjectsAlone(t *testing.T) {
	e := newApp(t, samplePosts())

	rdb := redisForTest(t)
	if err := rdb.Set(t.Context(), "someotherproject:home_html", "theirs", time.Hour).Err(); err != nil {
		t.Fatal(err)
	}

	if rec := post(t, e, "/cache/purge", `{"model":"analyticsIntegrations","id":"a1"}`); rec.Code != http.StatusOK {
		t.Fatalf("purge = %d", rec.Code)
	}

	got, err := rdb.Get(t.Context(), "someotherproject:home_html").Result()
	if err != nil || got != "theirs" {
		t.Errorf("another project's cached page was destroyed: %q %v", got, err)
	}
}
