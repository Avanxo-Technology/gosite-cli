package gosite

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/alicebob/miniredis/v2"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/addon"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/siteconfig"
)

// A test-only addon with a Configure hook. Register runs at init, after the
// shipped addons' own init: appending to Library first is what Register checks.
var (
	testConfigureCalls int
	testConfigureValue string
	testConfigureErr   error
)

func init() {
	addon.Library = append(addon.Library, "TestConfigure")
	addon.Register(addon.Addon{
		Name: "TestConfigure",
		Configure: func(c siteconfig.Config) error {
			testConfigureCalls++
			testConfigureValue = c.Values["commerce_region"]
			return testConfigureErr
		},
	})
}

// configureServer wires a stubbed environment and calls New, returning its
// error instead of failing, so a rejected Configure can be asserted on.
func configureServer(t *testing.T) (*Server, error) {
	t.Helper()
	mr := miniredis.RunT(t)
	cms := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	}))
	t.Cleanup(cms.Close)
	t.Setenv("GOSITE_PROJECT", "demo")
	t.Setenv("REDIS_URL", "redis://"+mr.Addr()+"/0")
	t.Setenv("COCKPIT_URL", cms.URL)
	if os.Getenv("APP_ENV") == "" {
		t.Setenv("APP_ENV", "development")
	}
	return New(&testSite{}, WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))))
}

func TestAddonConfigureReceivesSiteConfig(t *testing.T) {
	testConfigureCalls = 0
	testConfigureValue = ""
	testConfigureErr = nil
	writeSiteConfig(t, "project: demo\ncommerce_region: us\naddons:\n  - TestConfigure\n")

	s, err := configureServer(t)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if testConfigureCalls != 1 {
		t.Fatalf("Configure ran %d times, want 1", testConfigureCalls)
	}
	if testConfigureValue != "us" {
		t.Fatalf("Configure saw commerce_region=%q, want us", testConfigureValue)
	}
}

func TestAddonConfigureErrorStopsStartup(t *testing.T) {
	testConfigureCalls = 0
	testConfigureErr = errors.New(`commerce_region "zz" is not supported`)
	writeSiteConfig(t, "addons:\n  - TestConfigure\n")
	t.Cleanup(func() { testConfigureErr = nil })

	_, err := configureServer(t)
	if err == nil {
		t.Fatal("New succeeded with a failing Configure")
	}
	if !strings.Contains(err.Error(), "TestConfigure") || !strings.Contains(err.Error(), "commerce_region") {
		t.Fatalf("err = %v, want it to name the addon and the cause", err)
	}
}

// Blog has no Configure hook: enabling it must still start, proving an addon
// without the hook is unchanged.
func TestAddonWithoutConfigureStillStarts(t *testing.T) {
	testConfigureErr = nil
	writeSiteConfig(t, "project: demo\naddons:\n  - Blog\n")

	s, err := configureServer(t)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
}
