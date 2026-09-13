package views

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
	"testing/fstest"
)

const slotLayout = `{{define "layout"}}<html><head>{{template "gosite:head" .}}</head>` +
	`<body>{{template "gosite:body-start" .}}{{template "content" .}}{{template "gosite:body-end" .}}</body></html>{{end}}`

func themeFS(files map[string]string) fstest.MapFS {
	fsys := fstest.MapFS{}
	for name, body := range files {
		fsys[name] = &fstest.MapFile{Data: []byte(body)}
	}
	return fsys
}

func renderPage(t *testing.T, r *Renderer, page string) string {
	t.Helper()
	var buf bytes.Buffer
	if err := r.Page(&buf, page, map[string]any{"Title": "T", "Content": map[string]any{}}); err != nil {
		t.Fatal(err)
	}
	return buf.String()
}

// A layout that calls the slots gets everything core renders, in slot order,
// without naming a single core partial.
func TestSlotsCarryCorePartials(t *testing.T) {
	r := NewRenderer("/u",
		WithTheme(themeFS(map[string]string{
			"layout.html":     slotLayout,
			"pages/home.html": `{{define "content"}}BODY{{end}}`,
		})),
		WithIntegrations(func() []Integration {
			return []Integration{{Provider: "gtm", Config: map[string]any{"containerId": "GTM-X"}}}
		}),
		WithConsent(func() *Consent { return enabledConsent() }),
	)
	out := renderPage(t, r, "home")

	head := out[:strings.Index(out, "</head>")]
	for _, want := range []string{"<title>T</title>", `id="consent-config"`, `id="analytics-config"`} {
		if !strings.Contains(head, want) {
			t.Errorf("gosite:head is missing %s", want)
		}
	}
	if strings.Index(head, "consent-config") > strings.Index(head, "analytics-config") {
		t.Error("consent must come before analytics in gosite:head")
	}
	if !(strings.Index(out, "GTM-X") < strings.Index(out, "BODY")) {
		t.Error("GTM's noscript must be in gosite:body-start, before the content")
	}
	if !(strings.Index(out, "data-consent-open") > strings.Index(out, "BODY")) {
		t.Error("the consent link must be in gosite:body-end, after the content")
	}
}

func TestThemeOverridesCorePartialByName(t *testing.T) {
	r := NewRenderer("/u",
		WithTheme(themeFS(map[string]string{
			"layout.html":             slotLayout,
			"pages/home.html":         `{{define "content"}}BODY{{end}}`,
			"components/consent.html": `{{define "gosite:consent-link"}}<a data-consent-open>Cookies</a>{{end}}`,
		})),
		WithConsent(func() *Consent { return enabledConsent() }),
	)
	out := renderPage(t, r, "home")

	if !strings.Contains(out, "<a data-consent-open>Cookies</a>") {
		t.Error("the theme's gosite:consent-link was not used")
	}
	if strings.Contains(out, `class="consent-reopen"`) {
		t.Error("core's consent link still rendered next to the override")
	}
	if !strings.Contains(out, `id="consent-config"`) {
		t.Error("overriding one partial dropped another")
	}
}

// What an addon does: bring a partial and put it in a slot. A theme written
// before the addon existed shows it without an edit.
func TestSlotPartialReachesUnchangedLayout(t *testing.T) {
	r := NewRenderer("/u",
		WithTheme(themeFS(map[string]string{
			"layout.html":     slotLayout,
			"pages/home.html": `{{define "content"}}BODY{{end}}`,
		})),
		WithPartials(themeFS(map[string]string{"chat.html": `{{define "chat-widget"}}<div id="chat"></div>{{end}}`})),
		WithSlotPartial(SlotBodyEnd, "chat-widget"),
	)
	if out := renderPage(t, r, "home"); !strings.Contains(out, `<div id="chat"></div>`) {
		t.Error("a partial added to gosite:body-end did not render")
	}
}

func TestLegacyNamesRenderAndWarn(t *testing.T) {
	var logs bytes.Buffer
	r := NewRenderer("/u",
		WithLogger(slog.New(slog.NewTextHandler(&logs, nil))),
		WithTheme(themeFS(map[string]string{
			"layout.html": `{{define "layout"}}<head>{{template "consent-head" .}}</head>` +
				`<body>{{template "content" .}}{{template "consent-link" .}}</body>{{end}}`,
			"pages/home.html": `{{define "content"}}BODY{{end}}`,
		})),
		WithConsent(func() *Consent { return enabledConsent() }),
	)
	out := renderPage(t, r, "home")

	if !strings.Contains(out, `id="consent-config"`) || !strings.Contains(out, "data-consent-open") {
		t.Error("a pre-slot layout no longer renders consent")
	}
	if !strings.Contains(logs.String(), "use=gosite:head") {
		t.Errorf("no deprecation warning naming the slot; logs: %s", logs.String())
	}
}

func TestTemplateCalls(t *testing.T) {
	calls := TemplateCalls(`{{template "gosite:head" .}} {{- template "gosite:head" . -}} {{template "content" .}}`)
	if calls["gosite:head"] != 2 || calls["content"] != 1 {
		t.Errorf("calls = %v", calls)
	}
}
