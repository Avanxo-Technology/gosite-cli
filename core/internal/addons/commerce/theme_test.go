package commerce

import (
	"io/fs"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"time"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/app"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/handlers"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// A theme replaces an addon page by shipping a file of the same name.
func TestThemeOverridesCommercePDP(t *testing.T) {
	resetConfig()
	fake := storefrontFake(t)

	keyPath := filepath.Join(t.TempDir(), "publishable_key")
	if err := os.WriteFile(keyPath, []byte("pk_test"), 0o600); err != nil {
		t.Fatal(err)
	}
	key := NewPublishableKey(keyPath)
	key.Reload()
	client := NewClient(fake.URL, "pk_test", 15*time.Second)

	theme := fstest.MapFS{
		"layout.html":             {Data: []byte(`{{define "layout"}}<!doctype html><html><head>{{template "gosite:head" .}}</head><body>{{template "content" .}}</body></html>{{end}}`)},
		"pages/commerce-pdp.html": {Data: []byte(`{{define "content"}}THEME-PDP {{.Title}}{{end}}`)},
	}

	// development bypasses the page cache, which refuses tiny renders.
	cfg := config.Config{RedisURL: testRedisURL(t), Environment: "development"}
	a, err := app.NewApp(cfg, testLogger(), views.WithPages(fs.FS(pages)), views.WithTheme(theme))
	if err != nil {
		t.Fatalf("NewApp: %v", err)
	}
	t.Cleanup(func() { a.Close() })
	a.Redis.FlushDB(t.Context())

	mount := func(e *echo.Echo, h *handlers.Handlers) { mount(e, h, client, key) }
	e := app.NewRouter(a, app.RouterOptions{Mounts: []func(*echo.Echo, *handlers.Handlers){mount}})

	rec := get(t, e, "/producto/tee")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "THEME-PDP") {
		t.Fatalf("theme override not used: %d %s", rec.Code, rec.Body.String())
	}
}
