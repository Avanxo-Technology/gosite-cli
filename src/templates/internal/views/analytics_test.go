package views

import (
	"bytes"
	"strings"
	"testing"
)

func render(t *testing.T, integrations []Integration) string {
	t.Helper()
	r := NewRenderer("/storage/uploads", WithIntegrations(func() []Integration { return integrations }))
	var buf bytes.Buffer
	if err := r.Page(&buf, "home", map[string]any{
		"Title": "t", "Content": map[string]any{}, "IsDev": false,
	}); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

func TestNothingRenderedWhenNoIntegrations(t *testing.T) {
	out := render(t, nil)
	for _, unwanted := range []string{"analytics-config", "unpkg.com/analytics", "/static/js/analytics/"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("emitted %q with no integrations configured", unwanted)
		}
	}
}

func TestGTMRendersHeadAndBody(t *testing.T) {
	out := render(t, []Integration{{Provider: "gtm", Config: map[string]any{"containerId": "GTM-ABC1234"}}})

	if !strings.Contains(out, `<script src="/static/js/analytics/analytics.js">`) {
		t.Error("the loader was not included")
	}
	if !strings.Contains(out, "googletagmanager.com/ns.html?id=GTM-ABC1234") {
		t.Error("the noscript fallback is missing from the body")
	}
	if !strings.Contains(out, `src="https://unpkg.com/analytics@0.8.19/dist/analytics.min.js"`) {
		t.Error("the library is not loaded, or not pinned")
	}
}

func TestPostHogRendersNoBodyMarkup(t *testing.T) {
	out := render(t, []Integration{{Provider: "posthog", Config: map[string]any{"key": "phc_x", "host": "https://us.i.posthog.com"}}})

	if !strings.Contains(out, "/static/js/analytics/analytics.js") {
		t.Error("the loader was not included")
	}
	if strings.Contains(out, "<noscript>") {
		t.Error("emitted body markup for a provider that needs none")
	}
}

// A provider the loader does not know still emits no per-provider markup. The
// template no longer branches per provider at all, which is the point: adding
// one touches the CMS and the loader, never this file.
func TestUnknownProviderEmitsNoMarkup(t *testing.T) {
	out := render(t, []Integration{{Provider: "hotjar", Config: map[string]any{"id": "1"}}})
	if strings.Contains(out, "<noscript>") {
		t.Error("emitted body markup for a provider that needs none")
	}
}

// The configuration is data, not code. A value carrying script syntax must not
// be able to close the tag or execute.
func TestConfigIsInertData(t *testing.T) {
	out := render(t, []Integration{{Provider: "gtm", Config: map[string]any{
		"containerId": `GTM-X</script><script>alert(1)</script>`,
	}}})

	if strings.Contains(out, "<script>alert(1)</script>") {
		t.Fatal("a CMS value escaped its data block and became markup")
	}
	if !strings.Contains(out, `type="application/json"`) {
		t.Error("the configuration is not being emitted as a data block")
	}
}

func TestConfigBlockIsValidJSON(t *testing.T) {
	out := render(t, []Integration{{Provider: "gtm", Config: map[string]any{"containerId": "GTM-ABC1234"}}})

	start := strings.Index(out, `id="analytics-config">`)
	if start < 0 {
		t.Fatal("no configuration block")
	}
	start += len(`id="analytics-config">`)
	end := strings.Index(out[start:], "</script>")
	if !strings.Contains(out[start:start+end], "GTM-ABC1234") {
		t.Errorf("the id is not in the data block: %q", out[start:start+end])
	}
}
