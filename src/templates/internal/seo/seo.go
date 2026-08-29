// Package seo resolves SEO metadata for every page on the site.
//
// Resolution order:
//  1. webapp singleton defaults (global)
//  2. seoPages entry for path (per-page overrides)
//  3. Content-specific overrides (e.g. blog posts)
//
// Results are cached in Redis with a 5-minute TTL to avoid hammering Cockpit
// on every request.
package seo

import (
	"context"
	"encoding/json"
	"log/slog"
	"strings"
	"time"

	"__MODULE__/internal/cache"
	"__MODULE__/internal/cms"

	"golang.org/x/sync/singleflight"
)

const (
	// cacheTTL is how long resolved SEO data stays fresh.
	cacheTTL = 5 * time.Minute

	// cacheKeyPrefix namespaces SEO cache keys per project.
	//
	// The project name is not decoration: several projects share one Redis, and
	// without it every site on the host reads and overwrites the same
	// "seo:defaults" - one site serving another's title and description. It also
	// puts these keys under the prefix PurgeAll sweeps, so a site-wide purge
	// actually clears them.
	cacheKeyPrefix = "__PROJECT__:seo:"
)

// Data holds the resolved SEO metadata for a single page.
type Data struct {
	Title       string `json:"title"`
	Description string `json:"description"`
	Image       string `json:"image"`
	JSONLD      string `json:"jsonLd"`
	Canonical   string `json:"canonical"`
	NoIndex     bool   `json:"noIndex"`
	// SiteName is the site-wide brand name, used for og:site_name. It is not
	// overridable per page, so it only ever comes from the webapp defaults.
	SiteName string `json:"siteName"`
	// Type is the og:type of the page: "website" by default, "article" for a
	// blog post. Overridable per page, unlike the fields below it.
	Type string `json:"type"`
	// The rest are site-wide identity, filled from the webapp singleton on
	// every resolve. They are on Data so renderSEOTags needs one input.
	Lang          string `json:"lang"`
	Author        string `json:"author"`
	Publisher     string `json:"publisher"`
	PublisherLogo string `json:"publisherLogo"`
	TwitterHandle string `json:"twitterHandle"`
}

// WebappConfig holds the site-wide SEO defaults from the webapp singleton.
type WebappConfig struct {
	Favicon string `json:"favicon"`
	// SiteURL is the site's public origin, set in the webapp singleton. It is
	// what canonical URLs, og:url and sitemap.xml are built from.
	SiteURL string `json:"siteUrl"`
	// JSONLD is site-wide structured data. Empty means "generate a minimal
	// WebSite/Organization block from the other defaults".
	JSONLD             string `json:"jsonLd"`
	LLMText            string `json:"llmText"`
	RobotsTxt          string `json:"robotsTxt"`
	DefaultTitle       string `json:"defaultTitle"`
	DefaultDescription string `json:"defaultDescription"`
	DefaultImage       string `json:"defaultImage"`
	SiteName           string `json:"siteName"`
	Language           string `json:"language"`
	Author             string `json:"author"`
	Publisher          string `json:"publisher"`
	PublisherLogo      string `json:"publisherLogo"`
	TwitterHandle      string `json:"twitterHandle"`
}

// SEO resolves metadata for any path on the site.
type SEO struct {
	cms   *cms.Client
	cache *cache.Cache
	log   *slog.Logger
	sf    singleflight.Group

	// assetBase is config.AssetBaseURL: the public S3/MinIO endpoint, or the
	// local /storage/uploads mount. Needed because a Cockpit asset path is
	// relative to the uploads root and is not servable by this app.
	assetBase string
}

// Option configures an SEO resolver. Variadic rather than extra parameters so
// a project that has customised app.go keeps compiling when it syncs.
type Option func(*SEO)

// WithAssetBase supplies the base URL used to turn a Cockpit asset path into a
// browser-reachable URL (config.AssetBaseURL).
func WithAssetBase(base string) Option {
	return func(s *SEO) { s.assetBase = base }
}

// New creates an SEO resolver.
func New(cmsClient *cms.Client, cache *cache.Cache, log *slog.Logger, opts ...Option) *SEO {
	s := &SEO{cms: cmsClient, cache: cache, log: log}
	for _, apply := range opts {
		apply(s)
	}
	return s
}

// assetURL turns a Cockpit asset path into a browser-reachable URL.
//
// Cockpit stores an asset path relative to the uploads root and without a
// leading slash ("2026/08/28/foo.png"), and with S3 storage the file is not on
// this app's origin at all. Emitting the bare path yields a relative URL that
// resolves against the current page and 404s, so every asset that reaches a
// template or a redirect must go through here.
func (s *SEO) assetURL(path string) string {
	if path == "" {
		return ""
	}
	// Already absolute (or protocol-relative): the CMS gave us a full URL.
	if strings.HasPrefix(path, "http://") || strings.HasPrefix(path, "https://") || strings.HasPrefix(path, "//") {
		return path
	}
	if s.assetBase == "" {
		return "/" + strings.TrimLeft(path, "/")
	}
	return strings.TrimRight(s.assetBase, "/") + "/" + strings.TrimLeft(path, "/")
}

// Resolve returns merged SEO data for a path.
//
// The optional overrides parameter allows content-specific fields (e.g. from
// blog posts) to take precedence over seoPages and webapp defaults.
func (s *SEO) Resolve(path string, overrides ...*Data) *Data {
	// 1. Start with webapp defaults
	result := s.getDefaults()

	// 2. Check seoPages for this path
	if page := s.lookupPage(path); page != nil {
		result = merge(result, page)
	}

	// 3. Apply content-specific overrides
	if len(overrides) > 0 && overrides[0] != nil {
		result = merge(result, overrides[0])
	}

	// 4. Fill what only the site-wide config can answer. Both of these come
	// from Cockpit (the webapp singleton), never from the request: canonical
	// must be the URL the site declares for itself, not whatever host the
	// request happened to arrive on.
	config := s.fetchWebappConfig()

	if result.Canonical == "" {
		result.Canonical = canonicalURL(config.SiteURL, path)
	}
	if result.JSONLD == "" {
		result.JSONLD = defaultJSONLD(config)
	}
	if result.Type == "" {
		result.Type = "website"
	}

	// Site-wide identity: never per-page, so it is assigned rather than merged.
	result.Lang = lang(config.Language)
	result.Author = config.Author
	result.Publisher = config.Publisher
	result.PublisherLogo = config.PublisherLogo
	result.TwitterHandle = twitterHandle(config.TwitterHandle)

	return result
}

// lang normalises the singleton's language tag, defaulting to English so the
// document always declares one - an absent lang attribute is worse for screen
// readers than a wrong guess an editor can correct in the CMS.
func lang(value string) string {
	if value = strings.TrimSpace(value); value != "" {
		return value
	}
	return "en"
}

// ogLocale converts a BCP-47 tag ("es-ES") to the underscore form Open Graph
// expects ("es_ES").
func ogLocale(tag string) string {
	return strings.ReplaceAll(tag, "-", "_")
}

// twitterHandle normalises a handle to the leading-@ form the card tags want,
// accepting it written either way in the CMS.
func twitterHandle(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	return "@" + strings.TrimLeft(value, "@")
}

// canonicalURL joins the site origin from Cockpit with a page path.
//
// Returns empty when the singleton has no Site URL: a canonical tag pointing at
// a guessed origin is worse than none, so the tag is simply omitted until an
// editor fills the field in.
func canonicalURL(siteURL, path string) string {
	if siteURL == "" {
		return ""
	}
	if path == "" {
		path = "/"
	}
	return strings.TrimRight(siteURL, "/") + "/" + strings.TrimLeft(path, "/")
}

// defaultJSONLD builds a minimal schema.org WebSite block from the site-wide
// defaults, used when neither the page nor the singleton supplies its own.
//
// Returns empty when there is not even a site name, because a WebSite node with
// no name says nothing a crawler can use.
func defaultJSONLD(config *WebappConfig) string {
	if config == nil {
		return ""
	}
	if config.JSONLD != "" {
		return config.JSONLD
	}
	if config.SiteName == "" {
		return ""
	}

	node := map[string]any{
		"@context": "https://schema.org",
		"@type":    "WebSite",
		"name":     config.SiteName,
	}
	if config.SiteURL != "" {
		node["url"] = config.SiteURL
	}
	if config.DefaultDescription != "" {
		node["description"] = config.DefaultDescription
	}
	if config.DefaultImage != "" {
		node["image"] = config.DefaultImage
	}

	// Publisher as a nested Organization, which is the shape search engines
	// read - a <meta name="publisher"> is not something they consume.
	if config.Publisher != "" {
		publisher := map[string]any{
			"@type": "Organization",
			"name":  config.Publisher,
		}
		if config.PublisherLogo != "" {
			publisher["logo"] = map[string]any{
				"@type": "ImageObject",
				"url":   config.PublisherLogo,
			}
		}
		node["publisher"] = publisher
	}

	encoded, err := json.Marshal(node)
	if err != nil {
		return ""
	}
	return string(encoded)
}

// getDefaults returns the webapp singleton defaults, cached in Redis.
func (s *SEO) getDefaults() *Data {
	ctx := context.Background()
	key := cacheKeyPrefix + "defaults"

	// Try cache first
	cached, err := s.cache.Get(ctx, key)
	if err == nil && cached != nil {
		var data Data
		if json.Unmarshal(cached, &data) == nil {
			return &data
		}
	}

	// Fetch from Cockpit
	config := s.fetchWebappConfig()

	data := &Data{
		Title:       config.DefaultTitle,
		Description: config.DefaultDescription,
		Image:       config.DefaultImage,
		SiteName:    config.SiteName,
	}

	// Cache the result
	if bytes, err := json.Marshal(data); err == nil {
		s.cache.Set(ctx, key, bytes, cacheTTL)
	}

	return data
}

// lookupPage finds an SEO page entry by path.
func (s *SEO) lookupPage(path string) *Data {
	if path == "" {
		return nil
	}

	ctx := context.Background()
	key := cacheKeyPrefix + "page:" + path

	// Try cache first
	cached, err := s.cache.Get(ctx, key)
	if err == nil && cached != nil {
		var data Data
		if json.Unmarshal(cached, &data) == nil {
			return &data
		}
	}

	// Fetch from Cockpit
	item, err := s.cms.First(ctx, "seoPages", map[string]any{"path": path}, 0)
	if err != nil || item == nil {
		return nil
	}

	data := &Data{
		Title:       toString(item["title"]),
		Description: toString(item["description"]),
		Image:       s.assetURL(assetPath(item["image"])),
		JSONLD:      toString(item["jsonLd"]),
		Canonical:   toString(item["canonical"]),
		NoIndex:     toBool(item["noIndex"]),
	}

	// Cache the result (even if empty, to avoid repeated Cockpit queries)
	if bytes, err := json.Marshal(data); err == nil {
		s.cache.Set(ctx, key, bytes, cacheTTL)
	}

	return data
}

// fetchWebappConfig reads the webapp singleton from Cockpit.
func (s *SEO) fetchWebappConfig() *WebappConfig {
	ctx := context.Background()

	item := s.cms.Singleton(ctx, "webapp")

	config := &WebappConfig{
		DefaultTitle:       toString(item["defaultTitle"]),
		DefaultDescription: toString(item["defaultDescription"]),
		DefaultImage:       s.assetURL(assetPath(item["defaultImage"])),
		Favicon:            s.assetURL(assetPath(item["favicon"])),
		LLMText:            toString(item["llmText"]),
		RobotsTxt:          toString(item["robotsTxt"]),
		SiteName:           toString(item["siteName"]),
		SiteURL:            strings.TrimRight(toString(item["siteUrl"]), "/"),
		JSONLD:             toString(item["jsonLd"]),
		Language:           toString(item["language"]),
		Author:             toString(item["author"]),
		Publisher:          toString(item["publisher"]),
		PublisherLogo:      s.assetURL(assetPath(item["publisherLogo"])),
		TwitterHandle:      toString(item["twitterHandle"]),
	}

	return config
}

// GetWebappConfig returns the full webapp configuration (for templates).
func (s *SEO) GetWebappConfig() *WebappConfig {
	return s.fetchWebappConfig()
}

// FromMap converts a template-facing map (e.g. .SEOData from a handler) into
// a Data override. Unknown or missing keys are ignored; empty strings do not
// override anything because merge() skips them.
func FromMap(m map[string]any) *Data {
	if m == nil {
		return nil
	}
	return &Data{
		Title:       toString(m["title"]),
		Description: toString(m["description"]),
		Image:       toString(m["image"]),
		JSONLD:      toString(m["jsonLd"]),
		Canonical:   toString(m["canonical"]),
		NoIndex:     toBool(m["noIndex"]),
		Type:        toString(m["type"]),
	}
}

// ToMap converts resolved Data back into the map shape the template layer
// renders. Views never imports this package, so the boundary stays maps.
func ToMap(d *Data) map[string]any {
	if d == nil {
		return nil
	}
	return map[string]any{
		"title":         d.Title,
		"description":   d.Description,
		"image":         d.Image,
		"jsonLd":        d.JSONLD,
		"canonical":     d.Canonical,
		"noIndex":       d.NoIndex,
		"siteName":      d.SiteName,
		"type":          d.Type,
		"lang":          d.Lang,
		"author":        d.Author,
		"publisher":     d.Publisher,
		"publisherLogo": d.PublisherLogo,
		"twitterHandle": d.TwitterHandle,
	}
}

// FromBlogPost creates SEO overrides from a blog post's SEO fields.
func FromBlogPost(post map[string]any) *Data {
	if post == nil {
		return nil
	}

	return &Data{
		Title:       coalesce(toString(post["seoTitle"]), toString(post["title"])),
		Description: coalesce(toString(post["seoDescription"]), toString(post["excerpt"])),
		Image:       coalesce(assetPath(post["seoImage"]), assetPath(post["cover"])),
		JSONLD:      toString(post["seoJsonLd"]),
		Canonical:   toString(post["seoCanonical"]),
		NoIndex:     toBool(post["seoNoIndex"]),
	}
}

// merge returns a new Data with non-empty fields from override taking precedence.
func merge(base, override *Data) *Data {
	result := *base

	if override.Title != "" {
		result.Title = override.Title
	}
	if override.Description != "" {
		result.Description = override.Description
	}
	if override.Image != "" {
		result.Image = override.Image
	}
	if override.JSONLD != "" {
		result.JSONLD = override.JSONLD
	}
	if override.Canonical != "" {
		result.Canonical = override.Canonical
	}
	if override.NoIndex {
		result.NoIndex = override.NoIndex
	}
	if override.Type != "" {
		result.Type = override.Type
	}

	return &result
}

// --- helpers ---

func toString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func toBool(v any) bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return false
}

func coalesce(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// assetPath extracts the path from a Cockpit asset object (map with "path" key).
func assetPath(v any) string {
	if m, ok := v.(map[string]any); ok {
		if p, ok := m["path"].(string); ok {
			return p
		}
	}
	return ""
}

// SitemapEntry is one URL in the sitemap.
type SitemapEntry struct {
	Path    string
	LastMod time.Time
}

// SitemapPaths returns every path the seoPages collection declares, minus the
// ones marked noIndex - asking crawlers to index a page the CMS says not to
// index would contradict the meta tag on it.
//
// Not cached: sitemap.xml is fetched rarely, by crawlers, and a stale sitemap
// is worse than a slightly slower one.
func (s *SEO) SitemapPaths(ctx context.Context) []SitemapEntry {
	result, err := s.cms.Items(ctx, "seoPages", cms.Query{Limit: 500})
	if err != nil {
		s.log.Warn("sitemap: seoPages lookup failed", "error", err)
		return nil
	}

	entries := make([]SitemapEntry, 0, len(result.Items))

	for _, item := range result.Items {
		path := toString(item["path"])
		if path == "" || toBool(item["noIndex"]) {
			continue
		}

		entry := SitemapEntry{Path: path}
		if modified, ok := item["_modified"].(float64); ok && modified > 0 {
			entry.LastMod = time.Unix(int64(modified), 0).UTC()
		}
		entries = append(entries, entry)
	}

	return entries
}

// SiteURL is the origin the site declares for itself in the webapp singleton.
func (s *SEO) SiteURL() string {
	config := s.fetchWebappConfig()
	if config == nil {
		return ""
	}
	return config.SiteURL
}

// Purge removes cached SEO data for a specific path.
func (s *SEO) Purge(ctx context.Context, path string) error {
	keys := []string{cacheKeyPrefix + "defaults"}
	if path != "" {
		keys = append(keys, cacheKeyPrefix+"page:"+path)
	}
	return s.cache.Purge(ctx, keys...)
}

// PurgeAll removes all cached SEO data.
func (s *SEO) PurgeAll(ctx context.Context) error {
	return s.cache.PurgeGroup(ctx, cacheKeyPrefix)
}

// PurgeHook is the OnPurge hook for the SEO cache: a change to the webapp
// singleton or any seoPages entry invalidates every resolved-SEO key, because
// both feed the fallback chain for every path.
func (s *SEO) PurgeHook(ctx context.Context, model, id string) error {
	switch model {
	case "webapp", "seoPages", "":
		return s.PurgeAll(ctx)
	}
	return nil
}
