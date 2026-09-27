package commerce

import (
	"bytes"
	"html/template"
	"sync"
)

// Fragments are addon pages like any other (they live under pages/ and define
// "content", so the startup probe renders them and a theme could replace one),
// but they are served on their own, without the layout: htmx swaps them into
// the page. Parsing each file on its own keeps their "content" definitions from
// colliding.
var (
	fragmentMu    sync.Mutex
	fragmentCache = map[string]*template.Template{}
)

func renderFragment(file string, data any) ([]byte, error) {
	fragmentMu.Lock()
	t, ok := fragmentCache[file]
	if !ok {
		var err error
		t, err = template.ParseFS(pages, "pages/"+file)
		if err != nil {
			fragmentMu.Unlock()
			return nil, err
		}
		fragmentCache[file] = t
	}
	fragmentMu.Unlock()

	var buf bytes.Buffer
	if err := t.ExecuteTemplate(&buf, "content", data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}
