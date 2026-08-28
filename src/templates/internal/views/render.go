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

// Integration is one third-party tracking tool the layout should load, as
// configured in the CMS. Provider names what it is; Config is that provider's
// own settings, whatever shape they take.
//
// It lives here rather than with the code that reads it so the templates and
// the reader can share a type without either importing the other.
type Integration struct {
	Provider string
	Config   map[string]any
}

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
// Option configures a Renderer. Options rather than parameters so a capability
// can be added without changing the signature - a project that has customised
// its app.go would otherwise stop compiling the moment it syncs.
type Option func(*options)

type options struct {
	integrations func() []Integration
	seoResolver  func(path string, overrides ...any) map[string]any
	favicon      func() string
	robotsTxt    func() string
}

// WithIntegrations supplies what the analytics component should load.
//
// A function rather than a value because the answer lives in the CMS and
// changes while the process runs, while the renderer is built once at boot.
// Left unset it means "none", which is what a project without the Analytics
// addon gets.
func WithIntegrations(fn func() []Integration) Option {
	return func(o *options) { o.integrations = fn }
}

// WithSEO supplies the SEO resolver for rendering meta tags.
func WithSEO(fn func(path string, overrides ...any) map[string]any) Option {
	return func(o *options) { o.seoResolver = fn }
}

// WithFavicon supplies the favicon URL from the webapp singleton.
func WithFavicon(fn func() string) Option {
	return func(o *options) { o.favicon = fn }
}

// WithRobotsTxt supplies the robots.txt content from the webapp singleton.
func WithRobotsTxt(fn func() string) Option {
	return func(o *options) { o.robotsTxt = fn }
}

func NewRenderer(assetBase string, opts ...Option) *Renderer {
	var o options
	for _, apply := range opts {
		apply(&o)
	}
	integrations := o.integrations

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

	if integrations == nil {
		integrations = func() []Integration { return nil }
	}

	funcs := template.FuncMap{
		"assetURL": assetURL,
		// analyticsIntegrations is what the analytics component reads.
		//
		// A function rather than data passed by each handler: this belongs on
		// every page, and threading it through every data map would mean a page
		// added later silently loses its tracking, with nobody noticing for
		// weeks. Views call it as {{range analyticsIntegrations}}.
		"analyticsIntegrations": integrations,
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
		// jsonData marshals a value into a <script type="application/json">
		// block, where the browser must see JSON and not a JSON string.
		//
		// toJSON cannot be used there: inside a <script> element
		// html/template escapes its result as a JavaScript string literal, so
		// the page ends up with "[{\"a\":1}]" and JSON.parse returns a string
		// rather than the data. Returning template.JS emits it verbatim.
		//
		// That is safe here rather than a hole, and the reason is worth
		// keeping: encoding/json escapes <, > and & to \u003c, \u003e and
		// \u0026 by default, so no value can close the script element or open
		// a tag. The escaping that matters still happens - one layer down,
		// where it belongs.
		"jsonData": func(v any) (template.JS, error) {
			b, err := json.Marshal(v)
			return template.JS(b), err
		},
		// seoData resolves SEO for the given path and returns {title, tags} so
		// the layout can render the resolved <title> AND the meta block from a
		// single resolution:
		//
		//   {{$seo := seoData .Path .SEOData}}
		//   <title>{{or $seo.title .Title}}</title>
		//   {{$seo.tags}}
		//
		// The path argument is `any` rather than `string`: a page that does not
		// pass "Path" in its data map yields nil at the call site, and template
		// execution must degrade to webapp defaults instead of erroring.
		"seoData": func(pathArg any, overrides ...any) map[string]any {
			if o.seoResolver == nil {
				return map[string]any{}
			}
			path, _ := pathArg.(string)
			var dataOverrides []any
			if len(overrides) > 0 && overrides[0] != nil {
				dataOverrides = append(dataOverrides, overrides[0])
			}
			data := o.seoResolver(path, dataOverrides...)
			return map[string]any{
				"title": data["title"],
				"lang":  data["lang"],
				"tags":  renderSEOTags(data),
			}
		},
		// faviconUrl returns the favicon URL from the webapp singleton.
		"faviconUrl": func() string {
			if o.favicon == nil {
				return ""
			}
			return o.favicon()
		},
		// robotsTxtContent returns the robots.txt content from the webapp singleton.
		"robotsTxtContent": func() string {
			if o.robotsTxt == nil {
				return ""
			}
			return o.robotsTxt()
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
		// SEO keys
		"Path":    "",
		"SEOData": map[string]any{},
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

// renderSEOTags builds HTML meta tags from SEO data. The <title> element is
// deliberately NOT rendered here: the layout owns it, with the resolved SEO
// title as first choice and the handler's .Title as fallback.
func renderSEOTags(data map[string]any) template.HTML {
	if data == nil {
		return ""
	}

	var buf strings.Builder

	title, _ := data["title"].(string)
	description, _ := data["description"].(string)
	image, _ := data["image"].(string)
	canonical, _ := data["canonical"].(string)
	jsonLd, _ := data["jsonLd"].(string)
	noIndex, _ := data["noIndex"].(bool)
	siteName, _ := data["siteName"].(string)
	ogType, _ := data["type"].(string)
	lang, _ := data["lang"].(string)
	author, _ := data["author"].(string)
	publisher, _ := data["publisher"].(string)
	twitter, _ := data["twitterHandle"].(string)

	// Meta description
	if description != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="description" content="%s">`+"\n", description))
	}

	// Canonical
	if canonical != "" {
		buf.WriteString(fmt.Sprintf(`<link rel="canonical" href="%s">`+"\n", canonical))
	}

	// Author and publisher. The publisher also goes into the JSON-LD as an
	// Organization, which is the form search engines read; this tag is here
	// because SEO auditors look for it and only parse meta tags.
	if author != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="author" content="%s">`+"\n", author))
	}
	if publisher != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="publisher" content="%s">`+"\n", publisher))
	}

	// Open Graph
	if ogType == "" {
		ogType = "website"
	}
	buf.WriteString(fmt.Sprintf(`<meta property="og:type" content="%s">`+"\n", ogType))
	if lang != "" {
		buf.WriteString(fmt.Sprintf(`<meta property="og:locale" content="%s">`+"\n", strings.ReplaceAll(lang, "-", "_")))
	}
	if title != "" {
		buf.WriteString(fmt.Sprintf(`<meta property="og:title" content="%s">`+"\n", title))
	}
	if siteName != "" {
		buf.WriteString(fmt.Sprintf(`<meta property="og:site_name" content="%s">`+"\n", siteName))
	}
	if description != "" {
		buf.WriteString(fmt.Sprintf(`<meta property="og:description" content="%s">`+"\n", description))
	}
	if canonical != "" {
		buf.WriteString(fmt.Sprintf(`<meta property="og:url" content="%s">`+"\n", canonical))
	}
	if image != "" {
		buf.WriteString(fmt.Sprintf(`<meta property="og:image" content="%s">`+"\n", image))
	}

	// Twitter Card
	if image != "" {
		buf.WriteString(`<meta name="twitter:card" content="summary_large_image">` + "\n")
	} else {
		buf.WriteString(`<meta name="twitter:card" content="summary">` + "\n")
	}
	if title != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="twitter:title" content="%s">`+"\n", title))
	}
	if description != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="twitter:description" content="%s">`+"\n", description))
	}
	if image != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="twitter:image" content="%s">`+"\n", image))
	}
	if twitter != "" {
		buf.WriteString(fmt.Sprintf(`<meta name="twitter:site" content="%s">`+"\n", twitter))
		buf.WriteString(fmt.Sprintf(`<meta name="twitter:creator" content="%s">`+"\n", twitter))
	}

	// Robots. Always emitted: an auditor cannot tell "indexable" from "nobody
	// thought about it" when the tag is simply absent.
	if noIndex {
		buf.WriteString(`<meta name="robots" content="noindex, nofollow">` + "\n")
	} else {
		buf.WriteString(`<meta name="robots" content="index, follow">` + "\n")
	}

	// JSON-LD
	if jsonLd != "" {
		buf.WriteString(fmt.Sprintf(`<script type="application/ld+json">%s</script>`+"\n", jsonLd))
	}

	return template.HTML(buf.String())
}
