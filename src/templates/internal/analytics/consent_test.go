package analytics_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// singleton answers Cockpit's singleton endpoint with the given fields, and
// 404s anything else - which is what a project without the collection looks
// like, so Consent() is exercised against the same shapes production sees.
func singleton(fields map[string]any) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if fields == nil {
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"error":"not found"}`))
			return
		}
		json.NewEncoder(w).Encode(fields)
	}
}

func TestConsentEnabled(t *testing.T) {
	got := reader(t, "production", singleton(map[string]any{
		"enabled":     true,
		"copyVersion": "2026-09",
		"title":       "Cookies",
		"policyUrl":   "/privacy",
	})).Consent()

	if got == nil {
		t.Fatal("consent is configured and enabled, but nil was returned")
	}
	if !got.Enabled {
		t.Error("Enabled = false on an enabled singleton")
	}
	if got.CopyVersion != "2026-09" {
		t.Errorf("CopyVersion = %q", got.CopyVersion)
	}
	if got.Title != "Cookies" || got.PolicyURL != "/privacy" {
		t.Errorf("copy did not survive: %+v", got)
	}
}

// The one that matters most. A site that stores tracking keys and never filled
// in the banner must load nothing, and nil is how the templates and the
// browser are told so.
func TestConsentDisabledIsNil(t *testing.T) {
	if got := reader(t, "production", singleton(map[string]any{"enabled": false})).Consent(); got != nil {
		t.Fatalf("a disabled singleton returned %+v; nothing may be granted", got)
	}
}

func TestConsentAbsentIsNil(t *testing.T) {
	if got := reader(t, "production", singleton(nil)).Consent(); got != nil {
		t.Fatalf("a missing singleton returned %+v", got)
	}
}

func TestConsentUnreachableCMSIsNil(t *testing.T) {
	got := reader(t, "production", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}).Consent()

	if got != nil {
		t.Fatalf("an unreachable CMS returned %+v; it must fail closed", got)
	}
}

// An editor who enabled the banner and left a label blank must still get a
// usable button. The defaults are in the reader rather than the template
// because an empty control on a legal notice is a defect, not a style choice.
func TestConsentFillsEmptyLabels(t *testing.T) {
	got := reader(t, "production", singleton(map[string]any{
		"enabled": true,
		"title":   "   ",
	})).Consent()

	if got == nil {
		t.Fatal("nil on an enabled singleton")
	}
	for name, value := range map[string]string{
		"Title":       got.Title,
		"AcceptLabel": got.AcceptLabel,
		"RejectLabel": got.RejectLabel,
		"PrefsLabel":  got.PrefsLabel,
		"SaveLabel":   got.SaveLabel,
		"CopyVersion": got.CopyVersion,
	} {
		if value == "" {
			t.Errorf("%s is empty; an enabled banner must never render a blank control", name)
		}
	}
}

// The seeded copy and these fallbacks have to be the same language. An English
// fallback beside the Spanish the addon seeds would mean an editor deleting one
// field published a banner in two languages.
func TestFallbacksMatchTheSeededLanguage(t *testing.T) {
	got := reader(t, "production", singleton(map[string]any{"enabled": true})).Consent()

	if got == nil {
		t.Fatal("nil on an enabled singleton")
	}
	// Every visible string, checked against a word that only appears in the
	// Spanish wording. Cheap, and it fails the moment somebody reverts one.
	for name, value := range map[string]string{
		"Title":          got.Title,
		"AcceptLabel":    got.AcceptLabel,
		"RejectLabel":    got.RejectLabel,
		"PrefsLabel":     got.PrefsLabel,
		"SaveLabel":      got.SaveLabel,
		"PolicyLabel":    got.PolicyLabel,
		"NecessaryLabel": got.NecessaryLabel,
		"AnalyticsLabel": got.AnalyticsLabel,
	} {
		if value == "" {
			t.Errorf("%s is empty", name)
		}
	}
	if got.AcceptLabel != "Aceptar todo" || got.RejectLabel != "Rechazar todo" {
		t.Errorf("the fallbacks are not the seeded language: %q / %q", got.AcceptLabel, got.RejectLabel)
	}
}

// The category is passed through untouched, including a value this side does
// not recognise: the browser owns the category list, and duplicating it here
// would create two places to keep in step.
func TestCategoryReachesTheTemplates(t *testing.T) {
	got := reader(t, "production", items(map[string]any{
		"provider": "gtm", "enabled": true, "environments": "all",
		"category": " analytics ",
		"config":   map[string]any{"containerId": "GTM-ABC1234"},
	})).Integrations()

	if len(got) != 1 {
		t.Fatalf("got %d integrations", len(got))
	}
	if got[0].Category != "analytics" {
		t.Errorf("Category = %q, want it trimmed to analytics", got[0].Category)
	}
}

func TestNoCategoryStaysEmpty(t *testing.T) {
	got := reader(t, "production", items(gtm(true, "all"))).Integrations()

	if len(got) != 1 {
		t.Fatalf("got %d integrations", len(got))
	}
	// Empty, not defaulted: the browser resolves the provider's default, so
	// filling it in here would be the same decision made twice.
	if got[0].Category != "" {
		t.Errorf("Category = %q, want empty", got[0].Category)
	}
}
