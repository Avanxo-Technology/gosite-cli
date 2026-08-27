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

// APP_ENV is free text and deployments spell the same idea many ways. Folding
// it wrong is how a staging site ends up loading a client's production keys.
func TestEnvironmentFolding(t *testing.T) {
	for _, tc := range []struct{ appEnv, want string }{
		{"development", analytics.EnvDevelopment},
		{"dev", analytics.EnvDevelopment},
		{"local", analytics.EnvDevelopment},
		{"DEV", analytics.EnvDevelopment},
		{"qa", analytics.EnvQA},
		{"staging", analytics.EnvQA},
		{"stage", analytics.EnvQA},
		{"acceptance", analytics.EnvQA},
		{"uat", analytics.EnvQA},
		{"  Staging ", analytics.EnvQA},
		{"production", analytics.EnvProduction},
		{"prod", analytics.EnvProduction},
		{"", analytics.EnvProduction},
		{"whatever", analytics.EnvProduction},
	} {
		if got := analytics.Environment(tc.appEnv); got != tc.want {
			t.Errorf("Environment(%q) = %q, want %q", tc.appEnv, got, tc.want)
		}
	}
}

// The whole point: a staging deployment must not load production keys.
func TestStagingDoesNotLoadProductionKeys(t *testing.T) {
	if got := reader(t, "staging", items(gtm(true, "production"))).Integrations(); len(got) != 0 {
		t.Fatalf("a staging site loaded the production integration: %+v", got)
	}
	if got := reader(t, "staging", items(gtm(true, "qa"))).Integrations(); len(got) != 1 {
		t.Fatal("a staging site did not load its own qa integration")
	}
	if got := reader(t, "staging", items(gtm(true, "all"))).Integrations(); len(got) != 1 {
		t.Fatal("a staging site did not load an all-environments integration")
	}
}
