package analytics_test

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Avanxo-Technology/gosite-cli/core/cms"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/analytics"
	"github.com/Avanxo-Technology/gosite-cli/core/internal/config"
)

// readerWithLog is reader() with the log captured, so a test can assert on
// the warning a skipped duplicate leaves behind.
func readerWithLog(t *testing.T, env string, h http.HandlerFunc) (*analytics.Reader, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	cfg := config.Config{CockpitURL: srv.URL, Environment: env}
	var logs bytes.Buffer
	log := slog.New(slog.NewTextHandler(&logs, nil))
	return analytics.New(cms.New(cfg, slog.New(slog.NewTextHandler(io.Discard, nil))), cfg, log), &logs
}

func gtmEntry(id, env, configID string) map[string]any {
	return map[string]any{"_id": id, "provider": "gtm", "enabled": true, "environments": env,
		"config": map[string]any{"id": configID}}
}

// Two enabled entries for one provider, both applying here: one is loaded,
// the first in the response order, and the second is logged.
func TestDuplicateProviderLoadsOnceAndLogsTheSecond(t *testing.T) {
	r, logs := readerWithLog(t, "production", items(
		gtmEntry("a1", "all", "GTM-FIRST01"),
		gtmEntry("b2", "all", "GTM-SECOND2"),
	))

	got := r.Integrations()
	if len(got) != 1 {
		t.Fatalf("got %d integrations, want 1: %+v", len(got), got)
	}
	if got[0].Config["id"] != "GTM-FIRST01" {
		t.Fatalf("kept %v, want the first entry", got[0].Config["id"])
	}
	if !strings.Contains(logs.String(), "duplicate analytics integration") ||
		!strings.Contains(logs.String(), "id=b2") {
		t.Fatalf("no duplicate warning for the second entry:\n%s", logs.String())
	}
}

// An entry that is skipped for missing configuration does not reserve its
// provider: the next valid entry for the same provider still loads.
func TestMisconfiguredEntryDoesNotBlockItsProvider(t *testing.T) {
	broken := map[string]any{"_id": "a1", "provider": "gtm", "enabled": true,
		"environments": "all", "config": map[string]any{}}
	r, logs := readerWithLog(t, "production", items(broken, gtmEntry("b2", "all", "GTM-GOOD001")))

	got := r.Integrations()
	if len(got) != 1 || got[0].Config["id"] != "GTM-GOOD001" {
		t.Fatalf("got %+v, want the valid entry", got)
	}
	if strings.Contains(logs.String(), "duplicate") {
		t.Fatalf("a skipped entry was reported as a duplicate:\n%s", logs.String())
	}
}

// Entries for one provider that apply to different environments are not
// duplicates here: only the one for this deployment applies.
func TestSameProviderForDifferentEnvironmentsIsNotADuplicate(t *testing.T) {
	r, logs := readerWithLog(t, "production", items(
		gtmEntry("a1", "qa", "GTM-QAONLY1"),
		gtmEntry("b2", "production", "GTM-PRODUCT"),
	))

	got := r.Integrations()
	if len(got) != 1 || got[0].Config["id"] != "GTM-PRODUCT" {
		t.Fatalf("got %+v, want the production entry", got)
	}
	if strings.Contains(logs.String(), "duplicate") {
		t.Fatalf("a non-applicable entry was reported as a duplicate:\n%s", logs.String())
	}
}
