package gositetest

import (
	"strings"
	"testing"
	"testing/fstest"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

func fsys(layout, page string) fstest.MapFS {
	return fstest.MapFS{
		"layout.html":     {Data: []byte(layout)},
		"pages/home.html": {Data: []byte(page)},
	}
}

const okLayout = `{{define "layout"}}{{template "gosite:head" .}}{{template "gosite:body-start" .}}{{template "content" .}}{{template "gosite:body-end" .}}{{end}}`

func TestDefaultThemePasses(t *testing.T) {
	if p := ThemeProblems(views.DefaultTheme()); len(p) != 0 {
		t.Fatalf("core's own default theme fails its contract: %v", p)
	}
}

func TestValidTheme(t *testing.T) {
	if p := ThemeProblems(fsys(okLayout, `{{define "content"}}hi{{end}}`)); len(p) != 0 {
		t.Fatalf("problems = %v", p)
	}
}

func TestDuplicateSlot(t *testing.T) {
	layout := strings.Replace(okLayout, `{{template "gosite:body-end" .}}`, `{{template "gosite:body-end" .}}{{template "gosite:body-end" .}}`, 1)
	p := strings.Join(ThemeProblems(fsys(layout, `{{define "content"}}hi{{end}}`)), "\n")
	if !strings.Contains(p, `"gosite:body-end" is called 2 times`) {
		t.Fatalf("duplicate slot not reported: %s", p)
	}
}

func TestMissingSlot(t *testing.T) {
	layout := strings.Replace(okLayout, `{{template "gosite:head" .}}`, "", 1)
	p := strings.Join(ThemeProblems(fsys(layout, `{{define "content"}}hi{{end}}`)), "\n")
	if !strings.Contains(p, `"gosite:head" is never called`) {
		t.Fatalf("missing slot not reported: %s", p)
	}
}

func TestPageExecutionFailure(t *testing.T) {
	p := strings.Join(ThemeProblems(fsys(okLayout, `{{define "content"}}{{index .Content.items 3}}{{end}}`)), "\n")
	if !strings.Contains(p, "home") {
		t.Fatalf("a page that fails to execute was not reported: %s", p)
	}
}
