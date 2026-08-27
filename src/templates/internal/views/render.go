// Package views owns every piece of markup and the renderer that turns it into
// HTML. It never touches Redis, the CMS or the request: it is handed
// already-resolved data and decides only how that data looks.
package views

import (
	"embed"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"strings"

	"github.com/labstack/echo/v5"
)

// Templates are embedded so the binary is self-contained: nothing to copy into
// the image, and no chance of the markup drifting from the code.
//
//go:embed layout.html pages/*.html components/*.html
var files embed.FS

// Renderer implements echo.Renderer. Each entry is a page: layout + page body
// + every component, parsed once.
type Renderer struct {
	pages map[string]*template.Template
}

// NewRenderer parses every template at startup and panics on a malformed one,
// so a broken template fails the deploy instead of the first request.
//
// It also forces the html/template contextual-escaping pass at boot. Without
// this, a template that parses fine can still fail every request with errors
// like "'" in attribute name (Alpine + Go template quoting conflicts). The
// error is cached by html/template and only a process restart clears it.
//
// assetBase is the base URL for CMS assets (config.AssetBaseURL): with S3
// storage it is the public bucket/endpoint so images load CDN-style; otherwise
// it is the local /storage/uploads mount.
func NewRenderer(assetBase string) *Renderer {

	// assetURL turns a Cockpit asset object (a map with a "path") into a
	// browser-reachable URL. It returns the empty string when the field is
	// missing, so markup can always depend on CMS content.
	// Views call it as {{assetURL (index .Content "hero_portrait")}}.
	assetURL := func(asset any) string {
		if m, ok := asset.(map[string]any); ok {
			if p, ok := m["path"].(string); ok && p != "" {
				return strings.TrimRight(assetBase, "/") + "/" + strings.TrimLeft(p, "/")
			}
		}
		return ""
	}

	funcs := template.FuncMap{
		"assetURL": assetURL,
		// safeHTML renders a value as markup instead of escaping it, for rich
		// text an editor wrote in the CMS. This deliberately disables the XSS
		// protection html/template otherwise gives you, so it is only ever
		// correct for content authored by an authenticated Cockpit editor.
		// Never reach for it to render anything a visitor can submit.
		"safeHTML": func(v any) template.HTML {
			s, _ := v.(string)
			return template.HTML(s)
		},
		// toJSON marshals a value for Alpine x-data. It returns a plain string
		// so html/template escapes it in the attribute, keeping XSS out.
		"toJSON": func(v any) (string, error) {
			b, err := json.Marshal(v)
			return string(b), err
		},
	}

	// Every page is parsed as layout + that page + all components, so a page
	// can use any component without declaring anything.
	page := func(name string) *template.Template {
		return template.Must(template.New(name).Funcs(funcs).ParseFS(files,
			"layout.html",
			"pages/"+name+".html",
			"components/*.html",
		))
	}

	// Every file under pages/ becomes a page, named after the file. Adding a
	// page is dropping a file in - nothing to register here, and a feature that
	// brings its own pages (the blog) does not have to edit this file to
	// install or to be removed again.
	entries, err := files.ReadDir("pages")
	if err != nil {
		panic("views: cannot read embedded pages: " + err.Error())
	}

	pages := map[string]*template.Template{}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".html") {
			continue
		}
		name := strings.TrimSuffix(entry.Name(), ".html")
		pages[name] = page(name)
	}

	// Force the contextual-escaping pass now so a broken template panics
	// at boot instead of silently failing every request. probeData must
	// include every top-level key the handler passes to Page(); missing
	// keys cause "index of untyped nil" — add them here.
	// The union of what every page reads. Keys a page does not use cost
	// nothing, so this stays a superset rather than something per page.
	probeData := map[string]any{
		"Title":   "",
		"Content": map[string]any{},
		"IsDev":   true,
		// Blog pages, present whether or not the blog is installed.
		"Blog":    map[string]any{},
		"Post":    map[string]any{},
		"Posts":   []map[string]any{},
		"Author":  map[string]any{},
		"Meta":    map[string]any{},
		"Page":    1,
		"HasMore": false,
		"PrevURL": "",
		"NextURL": "",
		"Total":   0,
	}
	for name, t := range pages {
		if err := t.ExecuteTemplate(io.Discard, "layout", probeData); err != nil {
			panic(fmt.Sprintf("views: page %q failed at startup: %v\n"+
				"If this is a data error, add the missing key to probeData in render.go.", name, err))
		}
	}

	return &Renderer{pages: pages}
}

// Render satisfies echo.Renderer, so handlers can use c.Render directly.
func (r *Renderer) Render(_ *echo.Context, w io.Writer, name string, data any) error {
	return r.Page(w, name, data)
}

// Page renders to any writer, which is what lets the cache layer render into a
// buffer and store exactly the bytes that get served.
func (r *Renderer) Page(w io.Writer, name string, data any) error {
	t, ok := r.pages[name]
	if !ok {
		return fmt.Errorf("unknown page: %s", name)
	}
	return t.ExecuteTemplate(w, "layout", data)
}
