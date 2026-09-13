package views

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func renderWith(t *testing.T, integrations []Integration, consent *Consent) string {
	t.Helper()

	r := NewRenderer("/storage/uploads",
		WithIntegrations(func() []Integration { return integrations }),
		WithConsent(func() *Consent { return consent }),
	)

	var buf bytes.Buffer
	if err := r.Page(&buf, "home", map[string]any{
		"Title": "t", "Content": map[string]any{}, "IsDev": false,
	}); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

func enabledConsent() *Consent {
	return &Consent{
		Enabled:     true,
		CopyVersion: "1",
		Title:       "We use cookies",
		Body:        "Choose what runs.",
		AcceptLabel: "Accept all",
		RejectLabel: "Reject all",
		PrefsLabel:  "Preferences",
		SaveLabel:   "Save choices",
		PolicyURL:   "/privacy",
		PolicyLabel: "Privacy policy",
	}
}

// A project with no consent configured emits no banner at all - no empty tags,
// no empty JSON block. The same rule the analytics component follows.
func TestNothingRenderedWithoutConsent(t *testing.T) {
	out := renderWith(t, nil, nil)

	for _, unwanted := range []string{"consent-config", "consent.js", "consent.css", "data-consent-open"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("emitted %q with no consent configured", unwanted)
		}
	}
}

func TestConsentRendersScriptStylesheetAndData(t *testing.T) {
	out := renderWith(t, nil, enabledConsent())

	for _, want := range []string{
		`id="consent-config"`,
		`/static/js/analytics/consent.js`,
		`/static/css/consent.css`,
		`data-consent-open`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q", want)
		}
	}
}

// The copy must be JSON the browser can parse, not a JSON string. Getting this
// wrong is not hypothetical: the analytics block shipped doubly encoded once,
// and every value arrived as text.
func TestConsentConfigIsParseableJSON(t *testing.T) {
	out := renderWith(t, nil, enabledConsent())

	start := strings.Index(out, `id="consent-config">`)
	if start < 0 {
		t.Fatal("no consent-config block")
	}
	start += len(`id="consent-config">`)
	end := strings.Index(out[start:], "</script>")

	var parsed map[string]any
	if err := json.Unmarshal([]byte(out[start:start+end]), &parsed); err != nil {
		t.Fatalf("the block is not JSON an object can be read from: %v", err)
	}
	if parsed["Enabled"] != true {
		t.Errorf("Enabled did not survive: %v", parsed["Enabled"])
	}
	if parsed["CopyVersion"] != "1" {
		t.Errorf("CopyVersion did not survive: %v", parsed["CopyVersion"])
	}
}

// The gate has to be parsed before the thing it gates asks it anything.
func TestConsentScriptComesBeforeAnalytics(t *testing.T) {
	out := renderWith(t,
		[]Integration{{Provider: "gtm", Config: map[string]any{"containerId": "GTM-ABC1234"}}},
		enabledConsent())

	consentAt := strings.Index(out, "/static/js/analytics/consent.js")
	analyticsAt := strings.Index(out, "/static/js/analytics/analytics.js")

	if consentAt < 0 || analyticsAt < 0 {
		t.Fatalf("both scripts must be present: consent=%d analytics=%d", consentAt, analyticsAt)
	}
	if consentAt > analyticsAt {
		t.Error("consent.js is loaded after analytics.js; the cookie would be read too late")
	}
}

// Copy is CMS content and must never become markup. html/template escapes it
// into the JSON block; consent.js writes it with textContent. This checks the
// first of those two defences.
func TestConsentCopyWithScriptSyntaxIsInert(t *testing.T) {
	hostile := enabledConsent()
	hostile.Title = `</script><script>window.__pwned=1</script>`
	hostile.Body = `he said "yes" & <b>no</b>`

	out := renderWith(t, nil, hostile)

	if strings.Contains(out, "window.__pwned=1</script>") {
		t.Error("a closing script tag in the copy escaped the JSON block")
	}
	if strings.Contains(out, "<b>no</b>") {
		t.Error("markup in the copy reached the page unescaped")
	}
}

// The category travels to the browser, because the browser is what gates on it.
func TestIntegrationCategoryReachesTheJSONBlock(t *testing.T) {
	out := renderWith(t,
		[]Integration{{
			Provider: "gtm",
			Category: "analytics",
			Config:   map[string]any{"containerId": "GTM-ABC1234"},
		}},
		enabledConsent())

	start := strings.Index(out, `id="analytics-config">`)
	if start < 0 {
		t.Fatal("no analytics-config block")
	}
	start += len(`id="analytics-config">`)
	end := strings.Index(out[start:], "</script>")

	var parsed []map[string]any
	if err := json.Unmarshal([]byte(out[start:start+end]), &parsed); err != nil {
		t.Fatalf("not parseable JSON: %v", err)
	}
	if len(parsed) != 1 || parsed[0]["Category"] != "analytics" {
		t.Errorf("Category did not reach the browser: %+v", parsed)
	}
}

// Analytics does not depend on consent being configured to RENDER - it depends
// on it to LOAD, and that decision is the browser's. Rendering the keys with no
// banner would still be a bug, so this pins the pairing: keys present, gate
// absent, and analytics.js therefore refuses to load anything.
func TestAnalyticsStillRendersWithoutConsentSoTheGateCanRefuse(t *testing.T) {
	out := renderWith(t,
		[]Integration{{Provider: "gtm", Config: map[string]any{"containerId": "GTM-ABC1234"}}},
		nil)

	if !strings.Contains(out, `id="analytics-config"`) {
		t.Error("the analytics block vanished; the gate, not the renderer, decides what loads")
	}
	if strings.Contains(out, "consent.js") {
		t.Error("a consent script was emitted with no consent configured")
	}
}
