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
	"io/fs"
	"log/slog"
	"path"
	"regexp"
	"strings"

	"github.com/labstack/echo/v5"

	"github.com/Avanxo-Technology/gosite-cli/core/internal/deprecate"
)

// corePartials are the templates core owns: SEO, consent, analytics, and the
// names layouts used before slots. A site never copies them.
//
//go:embed partials/*.html
var corePartials embed.FS

// defaultTheme is used when the site supplies none: a layout, the demo home
// page and the purge button.
//
//go:embed theme
var defaultTheme embed.FS

// DefaultTheme returns the theme core renders with when none is given.
func DefaultTheme() fs.FS {
	sub, err := fs.Sub(defaultTheme, "theme")
	if err != nil {
		panic(err)
	}
	return sub
}

// The slots are the contract between core and a theme's layout. Core decides
// what goes into each; the layout decides only where each goes, and calls
// every one exactly once.
const (
	SlotHead      = "gosite:head"
	SlotBodyStart = "gosite:body-start"
	SlotBodyEnd   = "gosite:body-end"
)

// Slots lists every slot a layout must call.
var Slots = []string{SlotHead, SlotBodyStart, SlotBodyEnd}

// defaultSlotPartials is what core renders into each slot, in order.
//
// Consent comes before analytics in the head: the gate has to read the cookie
// before the thing it gates asks whether it may load. GTM's noscript fallback
// is the first thing in the body, where Google documents it.
func defaultSlotPartials() map[string][]string {
	return map[string][]string{
		SlotHead:      {"gosite:seo", "gosite:consent-head", "gosite:analytics-head"},
		SlotBodyStart: {"gosite:analytics-body"},
		SlotBodyEnd:   {"gosite:consent-link"},
	}
}

// legacyNames maps a template name layouts called before slots to the slot
// that now renders it.
var legacyNames = map[string]string{
	"consent-head":   SlotHead,
	"analytics-head": SlotHead,
	"analytics-body": SlotBodyStart,
	"consent-link":   SlotBodyEnd,
}

// Integration is one third-party tracking tool the layout should load, as
// configured in the CMS. Provider names what it is; Config is that provider's
// own settings, whatever shape they take.
//
// It lives here rather than with the code that reads it so the templates and
// the reader can share a type without either importing the other.
type Integration struct {
	Provider string
	Config   map[string]any

	// Category is the consent category this entry needs before it may load:
	// "analytics" or "marketing". Empty means the CMS did not override it and
	// the browser registry's own default for the provider applies.
	//
	// Only the browser ever compares it against a visitor's decision. Nothing
	// on the server reads consent, because a cached page must be identical for
	// a visitor who accepted and one who refused.
	Category string
}

// Consent is the banner's configuration, as an editor filled it in.
//
// It carries no per-visitor state, on purpose. The decision lives in a cookie
// the browser owns; if any of it reached a rendered page, the first visitor's
// choice would be cached and served to everyone else.
type Consent struct {
	// Enabled is whether this site asks for consent at all. When it is false
	// the browser treats every optional category as refused, so a site that
	// forgot to configure the banner loads no tracking rather than all of it.
	Enabled bool

	// CopyVersion identifies the text below. It is stored inside the visitor's
	// cookie so a later server-side record can say which wording a decision
	// was made against. Changing it does not re-ask.
	CopyVersion string

	Title       string
	Body        string
	AcceptLabel string
	RejectLabel string
	PrefsLabel  string
	SaveLabel   string

	PolicyLabel string
	PolicyURL   string

	AnalyticsLabel       string
	AnalyticsDescription string
	MarketingLabel       string
	MarketingDescription string
	NecessaryLabel       string
	NecessaryDescription string
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
	theme        fs.FS
	partials     []fs.FS
	slotPartials map[string][]string
	log          *slog.Logger

	integrations func() []Integration
	consent      func() *Consent
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

// WithConsent supplies the cookie banner's configuration.
//
// A function, like WithIntegrations, because it lives in the CMS. Left unset
// it means no consent configuration, which the browser must read as no consent
// given - never as consent assumed.
func WithConsent(fn func() *Consent) Option {
	return func(o *options) { o.consent = fn }
}

// WithTheme supplies the site's templates: layout.html, pages/*.html and,
// optionally, components/*.html. Anything the theme defines under a core
// partial's name replaces that partial.
func WithTheme(theme fs.FS) Option {
	return func(o *options) { o.theme = theme }
}

// WithPartials adds templates (every *.html at the root of fsys) parsed after
// core's and before the theme's, so a theme can still override them. Addons
// use it together with WithSlotPartial.
func WithPartials(fsys fs.FS) Option {
	return func(o *options) { o.partials = append(o.partials, fsys) }
}

// WithSlotPartial appends a template to a slot, after core's own partials.
func WithSlotPartial(slot, name string) Option {
	return func(o *options) {
		if o.slotPartials == nil {
			o.slotPartials = defaultSlotPartials()
		}
		o.slotPartials[slot] = append(o.slotPartials[slot], name)
	}
}

// WithLogger is where deprecation warnings go.
func WithLogger(log *slog.Logger) Option {
	return func(o *options) { o.log = log }
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
	if o.theme == nil {
		o.theme = DefaultTheme()
	}
	if o.slotPartials == nil {
		o.slotPartials = defaultSlotPartials()
	}
	integrations := o.integrations
	consent := o.consent

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

	if consent == nil {
		consent = func() *Consent { return nil }
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
		// consentSettings is what the consent component reads. Nil means the
		// banner renders nothing at all, and the browser gates everything.
		"consentSettings": consent,
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
		// htmlLang is the document language from the resolved SEO data, "en"
		// when none is set: <html lang="{{htmlLang .Path .SEOData}}">.
		"htmlLang": func(pathArg any, overrides ...any) string {
			if o.seoResolver == nil {
				return "en"
			}
			path, _ := pathArg.(string)
			var dataOverrides []any
			if len(overrides) > 0 && overrides[0] != nil {
				dataOverrides = append(dataOverrides, overrides[0])
			}
			if lang, _ := o.seoResolver(path, dataOverrides...)["lang"].(string); lang != "" {
				return lang
			}
			return "en"
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

	slots := slotTemplates(o.slotPartials)
	warnLegacyNames(o.theme, o.log)

	// Every page is parsed as core partials, then addon partials, then the
	// theme's layout, components and that page. Later definitions replace
	// earlier ones with the same name, which is how a theme overrides a core
	// partial. A page can use any component without declaring anything.
	page := func(name string) *template.Template {
		t := template.New(name).Funcs(funcs)
		template.Must(t.ParseFS(corePartials, "partials/*.html"))
		template.Must(t.Parse(slots))
		for _, fsys := range o.partials {
			parseGlob(t, fsys, "*.html")
		}
		parseGlob(t, o.theme, "layout.html")
		parseGlob(t, o.theme, "components/*.html")
		parseGlob(t, o.theme, "pages/"+name+".html")
		return t
	}

	// Every file under pages/ becomes a page, named after the file. Adding a
	// page is dropping a file in - nothing to register here, and a feature that
	// brings its own pages (the blog) does not have to edit this file to
	// install or to be removed again.
	entries, err := fs.ReadDir(o.theme, "pages")
	if err != nil {
		panic("views: the theme has no pages directory: " + err.Error())
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
		"Data":    map[string]any{},
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

// slotTemplates defines each slot as the ordered calls of its partials.
func slotTemplates(partials map[string][]string) string {
	var b strings.Builder
	for _, slot := range Slots {
		fmt.Fprintf(&b, "{{define %q}}", slot)
		for _, name := range partials[slot] {
			fmt.Fprintf(&b, "{{template %q .}}", name)
		}
		b.WriteString("{{end}}")
	}
	return b.String()
}

// parseGlob parses the files matching pattern, if any. A theme without
// components is valid, and template.ParseFS fails on a pattern with no match.
func parseGlob(t *template.Template, fsys fs.FS, pattern string) {
	matches, err := fs.Glob(fsys, pattern)
	if err != nil {
		panic(fmt.Sprintf("views: bad pattern %q: %v", pattern, err))
	}
	for _, m := range matches {
		data, err := fs.ReadFile(fsys, m)
		if err != nil {
			panic(fmt.Sprintf("views: cannot read %s: %v", m, err))
		}
		if _, err := t.New(path.Base(m)).Parse(string(data)); err != nil {
			panic(fmt.Sprintf("views: %s: %v", m, err))
		}
	}
}

// templateCall matches {{template "name"}} and {{- template "name" -}}.
var templateCall = regexp.MustCompile(`\{\{-?\s*template\s+"([^"]+)"`)

// TemplateCalls counts, per name, the {{template}} calls in a theme file.
func TemplateCalls(src string) map[string]int {
	calls := map[string]int{}
	for _, m := range templateCall.FindAllStringSubmatch(src, -1) {
		calls[m[1]]++
	}
	return calls
}

// warnLegacyNames logs, once each, the pre-slot names a theme still calls.
func warnLegacyNames(theme fs.FS, log *slog.Logger) {
	_ = fs.WalkDir(theme, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(p, ".html") {
			return nil
		}
		data, err := fs.ReadFile(theme, p)
		if err != nil {
			return nil
		}
		for name := range TemplateCalls(string(data)) {
			if slot, ok := legacyNames[name]; ok {
				deprecate.Warn(log, "template "+name, slot)
			}
		}
		return nil
	})
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
