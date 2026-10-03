package commerce

import (
	"encoding/json"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/app"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

func testRedisURL(t *testing.T) string {
	t.Helper()
	url := os.Getenv("REDIS_TEST_URL")
	if url == "" {
		t.Skip("REDIS_TEST_URL is not set; skipping storefront tests that need Redis")
	}
	return url
}

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// storefrontFake answers the three Store API calls the storefront makes, with
// one product "tee" in category "shirts" and one "mug" with no category.
func storefrontFake(t *testing.T) *httptest.Server {
	t.Helper()
	products := []map[string]any{
		productJSON("prod_1", "Tee", "tee", "pcat_1", "59900", 5),
		productJSON("prod_2", "Mug", "mug", "", "29900", 0),
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/store/regions"):
			_, _ = w.Write([]byte(`{"regions":[{"id":"reg_1","currency_code":"cop","countries":[{"iso_2":"co"}]}]}`))
		case strings.HasSuffix(r.URL.Path, "/store/product-categories"):
			_, _ = w.Write([]byte(`{"product_categories":[{"id":"pcat_1","name":"Shirts","handle":"shirts"}]}`))
		case strings.HasSuffix(r.URL.Path, "/store/products"):
			q := r.URL.Query()
			handle := q.Get("handle")
			category := q.Get("category_id")
			matched := []map[string]any{}
			for _, p := range products {
				if handle != "" && p["handle"] != handle {
					continue
				}
				if category != "" {
					cats, _ := p["category_ids"].([]string)
					if len(cats) == 0 || cats[0] != category {
						continue
					}
				}
				matched = append(matched, p)
			}
			count := len(matched)
			offset := atoiDefault(q.Get("offset"), 0)
			limit := atoiDefault(q.Get("limit"), len(matched))
			if offset > len(matched) {
				matched = nil
			} else {
				matched = matched[offset:]
			}
			if limit < len(matched) {
				matched = matched[:limit]
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"products": matched, "count": count, "offset": offset, "limit": limit,
			})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func productJSON(id, title, handle, categoryID, price string, stock int) map[string]any {
	cats := []string{}
	if categoryID != "" {
		cats = append(cats, categoryID)
	}
	return map[string]any{
		"id": id, "title": title, "handle": handle, "thumbnail": "/img/" + handle + ".jpg",
		"category_ids": cats,
		"variants": []map[string]any{
			{
				"id": id + "_v1", "title": "Default",
				// The shape Medusa v2 sends: a list of option values, not a map.
				"options": []map[string]any{{
					"id": id + "_ov1", "value": "Default", "option_id": id + "_o1",
					"option": map[string]any{"id": id + "_o1", "title": "Default"},
				}},
				"calculated_price":   map[string]any{"calculated_amount": json.Number(price), "currency_code": "cop"},
				"inventory_quantity": stock,
			},
		},
	}
}

func atoiDefault(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	n := 0
	for _, c := range s {
		if c < '0' || c > '9' {
			return fallback
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// newStorefront mounts the storefront against the fake, with the key already
// loaded (or not, when ready is false).
func newStorefront(t *testing.T, ready bool) *echo.Echo {
	t.Helper()
	// Configure writes package state shared with the config tests; start from
	// the defaults so this test does not depend on test order.
	resetConfig()
	fake := storefrontFake(t)

	keyPath := filepath.Join(t.TempDir(), "publishable_key")
	if ready {
		if err := os.WriteFile(keyPath, []byte("pk_test"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	key := NewPublishableKey(keyPath)
	if ready {
		key.Reload()
	}
	client := NewClient(fake.URL, "pk_test", 15*time.Second)

	cfg := config.Config{
		RedisURL:    testRedisURL(t),
		Environment: "production",
	}
	a, err := app.NewApp(cfg, testLogger(), views.WithPages(fs.FS(pages)))
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	a.Redis.FlushDB(t.Context())

	mount := func(e *echo.Echo, h *handlers.Handlers) { mount(e, h, client, key) }
	return app.NewRouter(a, app.RouterOptions{Mounts: []func(*echo.Echo, *handlers.Handlers){mount}})
}

func get(t *testing.T, e *echo.Echo, path string) *httptest.ResponseRecorder {
	t.Helper()
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	return rec
}

func TestPLPListsProducts(t *testing.T) {
	e := newStorefront(t, true)
	rec := get(t, e, "/tienda")
	if rec.Code != http.StatusOK {
		t.Fatalf("/tienda = %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Tee") || !strings.Contains(body, "59900 COP") {
		t.Fatalf("PLP missing product or price: %s", body)
	}
	if !strings.Contains(body, `href="/producto/tee"`) {
		t.Error("PLP does not link to the PDP")
	}
}

func TestPLPCategoryFilter(t *testing.T) {
	e := newStorefront(t, true)

	rec := get(t, e, "/tienda?category=shirts")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Tee") {
		t.Fatalf("filtered PLP = %d", rec.Code)
	}
	if strings.Contains(rec.Body.String(), "Mug") {
		t.Error("filtered PLP listed a product outside the category")
	}

	if rec := get(t, e, "/tienda?category=nope"); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown category = %d, want 404", rec.Code)
	}
}

func TestPLPCachesPerRegion(t *testing.T) {
	e := newStorefront(t, true)
	if rec := get(t, e, "/tienda"); rec.Header().Get("X-Cache") != "MISS" {
		t.Fatalf("first PLP X-Cache = %q", rec.Header().Get("X-Cache"))
	}
	if rec := get(t, e, "/tienda"); rec.Header().Get("X-Cache") != "HIT" {
		t.Fatalf("second PLP X-Cache = %q, want HIT", rec.Header().Get("X-Cache"))
	}
}

func TestPDPAndUnknownHandle(t *testing.T) {
	e := newStorefront(t, true)
	rec := get(t, e, "/producto/tee")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Tee") {
		t.Fatalf("PDP = %d", rec.Code)
	}
	if rec := get(t, e, "/producto/does-not-exist"); rec.Code != http.StatusNotFound {
		t.Fatalf("unknown PDP = %d, want 404", rec.Code)
	}
}

func TestBuyIslandShowsPriceAndAddForm(t *testing.T) {
	e := newStorefront(t, true)
	rec := get(t, e, "/_commerce/buy/tee")
	if rec.Code != http.StatusOK {
		t.Fatalf("buy island = %d", rec.Code)
	}
	body := rec.Body.String()
	for _, want := range []string{"59900 COP", "Add to cart", "prod_1_v1", "5 in stock"} {
		if !strings.Contains(body, want) {
			t.Errorf("buy island missing %q: %s", want, body)
		}
	}
	// The island is live, never a cached full page.
	if strings.Contains(body, "<html") {
		t.Error("buy island returned a full document")
	}
}

func TestBuyIslandOutOfStock(t *testing.T) {
	e := newStorefront(t, true)
	rec := get(t, e, "/_commerce/buy/mug")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Out of stock") {
		t.Fatalf("out-of-stock island = %d: %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), "Add to cart") {
		t.Error("out-of-stock variant still offered an add form")
	}
}

func TestStoreRoutesAnswer503UntilKeyIsWritten(t *testing.T) {
	e := newStorefront(t, false)
	for _, path := range []string{"/tienda", "/producto/tee", "/_commerce/buy/tee"} {
		if rec := get(t, e, path); rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s = %d, want 503 before the key exists", path, rec.Code)
		}
	}
}

// A query string the page does not use must not create a new cache entry:
// otherwise anyone can flood Redis and Medusa with /tienda?x=1, ?x=2, ...
func TestPLPIgnoresUnusedQueryInCacheKey(t *testing.T) {
	e := newStorefront(t, true)
	if rec := get(t, e, "/tienda?x=1"); rec.Header().Get("X-Cache") != "MISS" {
		t.Fatalf("first PLP X-Cache = %q", rec.Header().Get("X-Cache"))
	}
	if rec := get(t, e, "/tienda?x=2&utm_source=y"); rec.Header().Get("X-Cache") != "HIT" {
		t.Fatalf("PLP with another unused query X-Cache = %q, want HIT", rec.Header().Get("X-Cache"))
	}
	if rec := get(t, e, "/producto/tee?x=1"); rec.Code != 200 {
		t.Fatalf("PDP status = %d", rec.Code)
	}
	if rec := get(t, e, "/producto/tee?x=2"); rec.Header().Get("X-Cache") != "HIT" {
		t.Fatalf("PDP with another unused query X-Cache = %q, want HIT", rec.Header().Get("X-Cache"))
	}
}
