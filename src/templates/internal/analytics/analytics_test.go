package analytics_test

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"__MODULE__/internal/analytics"
	"__MODULE__/internal/cms"
	"__MODULE__/internal/config"
	"__MODULE__/internal/views"
)

func reader(t *testing.T, env string, h http.HandlerFunc) *analytics.Reader {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	cfg := config.Config{CockpitURL: srv.URL, Environment: env}
	return analytics.New(cms.New(cfg, slog.New(slog.NewTextHandler(io.Discard, nil))), cfg,
		slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func items(entries ...map[string]any) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Only enabled entries are asked for; the fake honours that so the
		// test exercises the same filter production uses.
		var filter map[string]any
		json.Unmarshal([]byte(r.URL.Query().Get("filter")), &filter)
		out := []map[string]any{}
		for _, e := range entries {
			if want, ok := filter["enabled"]; ok && e["enabled"] != want {
				continue
			}
			out = append(out, e)
		}
		json.NewEncoder(w).Encode(map[string]any{"data": out, "meta": map[string]any{"total": len(out)}})
	}
}

func gtm(enabled bool, env string) map[string]any {
	return map[string]any{"provider": "gtm", "enabled": enabled, "environments": env,
		"config": map[string]any{"id": "GTM-ABC1234"}}
}

func TestReturnsEnabledIntegrations(t *testing.T) {
	got := reader(t, "production", items(gtm(true, "all"))).Integrations()
	if len(got) != 1 || got[0].Provider != "gtm" {
		t.Fatalf("got %+v", got)
	}
	if got[0].Config["id"] != "GTM-ABC1234" {
		t.Errorf("config = %v", got[0].Config)
	}
}

func TestDisabledIsNotReturned(t *testing.T) {
	if got := reader(t, "production", items(gtm(false, "all"))).Integrations(); len(got) != 0 {
		t.Fatalf("a disabled entry was returned: %+v", got)
	}
}

// The point of the environments field: development traffic must not reach a
// client's production account.
func TestProductionOnlyEntryIsHiddenInDevelopment(t *testing.T) {
	if got := reader(t, "development", items(gtm(true, "production"))).Integrations(); len(got) != 0 {
		t.Fatalf("a production-only entry loaded in development: %+v", got)
	}
}

func TestProductionOnlyEntryLoadsInProduction(t *testing.T) {
	if got := reader(t, "production", items(gtm(true, "production"))).Integrations(); len(got) != 1 {
		t.Fatalf("got %+v", got)
	}
}

func TestUnsetEnvironmentCountsAsProduction(t *testing.T) {
	if got := reader(t, "", items(gtm(true, "production"))).Integrations(); len(got) != 1 {
		t.Fatalf("an unset APP_ENV should behave as production, got %+v", got)
	}
}

func TestEntryWithoutConfigIsSkipped(t *testing.T) {
	e := gtm(true, "all")
	delete(e, "config")
	if got := reader(t, "production", items(e)).Integrations(); len(got) != 0 {
		t.Fatalf("an entry with no configuration was returned: %+v", got)
	}
}

func TestNoneConfigured(t *testing.T) {
	if got := reader(t, "production", items()).Integrations(); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

// A project without the addon has no such collection. That is normal, not an
// error, and must not break a page.
func TestMissingCollectionIsNotAnError(t *testing.T) {
	got := reader(t, "production", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}).Integrations()
	if len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

func TestUnreachableCMSLoadsNothingAndDoesNotPanic(t *testing.T) {
	got := reader(t, "production", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}).Integrations()
	if len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}

var _ = views.Integration{}
