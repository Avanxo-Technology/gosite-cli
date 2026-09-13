// Package gositetest checks a site against its contract with core. A site's
// tests call it once:
//
//	func TestTheme(t *testing.T) {
//		gositetest.CheckTheme(t, site.Theme())
//	}
//
// It replaces view tests that render the scaffold's demo data, which fail on
// any real site whose templates read its own keys.
package gositetest

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"strings"
	"testing"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/views"
)

// CheckTheme fails t when the theme's layout misses a slot or calls one more
// than once, or when any page fails to parse or to execute with empty data.
func CheckTheme(t testing.TB, theme fs.FS) {
	t.Helper()
	for _, problem := range ThemeProblems(theme) {
		t.Error(problem)
	}
}

// ThemeProblems is CheckTheme without a testing.TB, for tools.
func ThemeProblems(theme fs.FS) (problems []string) {
	layout, err := fs.ReadFile(theme, "layout.html")
	if err != nil {
		return []string{"layout.html: " + err.Error()}
	}
	calls := views.TemplateCalls(string(layout))
	for _, slot := range views.Slots {
		switch n := calls[slot]; {
		case n == 0:
			problems = append(problems, fmt.Sprintf("layout.html: slot %q is never called; core features rendered there will be missing", slot))
		case n > 1:
			problems = append(problems, fmt.Sprintf("layout.html: slot %q is called %d times; its markup would render %d times", slot, n, n))
		}
	}

	// Building the renderer parses every page and executes it once with empty
	// data; it panics on the first failure.
	var r *views.Renderer
	func() {
		defer func() {
			if v := recover(); v != nil {
				problems = append(problems, fmt.Sprint(v))
			}
		}()
		r = views.NewRenderer("/storage/uploads",
			views.WithTheme(theme),
			views.WithLogger(slog.New(slog.NewTextHandler(io.Discard, nil))),
		)
	}()
	if r == nil {
		return problems
	}

	pages, _ := fs.Glob(theme, "pages/*.html")
	for _, p := range pages {
		name := strings.TrimSuffix(strings.TrimPrefix(p, "pages/"), ".html")
		var buf bytes.Buffer
		data := map[string]any{"Title": "", "Path": "/", "Content": map[string]any{}, "SEOData": map[string]any{}, "Data": map[string]any{}}
		if err := r.Page(&buf, name, data); err != nil {
			problems = append(problems, fmt.Sprintf("pages/%s.html: %v", name, err))
		}
	}
	return problems
}
