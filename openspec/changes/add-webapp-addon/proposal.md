## Why

The current gosite scaffold has 6 small infrastructure addons (AssetPathFix, AssetsUpload, StarterContent, CachePurge, CloudStorage, ModelManager) that are independent, lack admin screens, and are scattered across `src/addons/`. Additionally, there is **zero SEO management** — no global metadata configuration, no per-page SEO overrides, no robots.txt, no favicon handling, no JSON-LD support, and the `seo.html` template only works for blog pages with hardcoded `og:type="article"`.

We need a unified "webapp" addon that:
1. Organizes these loose infrastructure addons under one roof
2. Provides a proper SEO management system with admin UI visible in the sidebar (like Blog, Analytics, Forms, Replica)
3. Enables every page on the site to have proper SEO metadata

## What Changes

### Cockpit Addon (PHP)
- **New `Webapp` addon** in `src/addons/Webapp/` — always installed (built-in)
- **Singleton `webapp`** — site-wide SEO config: favicon, LLM text, robots.txt, default title/description/image
- **Collection `seoPages`** — per-path SEO overrides: path, title, description, image, jsonLd, canonical, noIndex
- **Admin screen** — visible in sidebar with SEO config (top) + SEO pages list (bottom)
- **Absorbs 6 addons** — each becomes a module file inside `Webapp/modules/`, functionality unchanged
- **ACL permission** — `webapp/manage` for all admin access
- **Blog SEO fields** — add `seoTitle`, `seoDescription`, `seoImage`, `seoJsonLd`, `seoCanonical`, `seoNoIndex` to `blogPosts` model

### Go Package (shared template)
- **New `internal/seo/` package** — reads webapp singleton + seoPages collection from Cockpit, caches in Redis (TTL 5min)
- **`Resolve(path, ...overrides)` function** — unified SEO resolution: defaults → seoPages → content overrides
- **`FromBlogPost()` helper** — creates SEO overrides from blog post fields

### Template Changes
- **`seo.html`** — rewritten to support full SEO: proper `og:type` (website/article), robots meta, JSON-LD, conditional rendering
- **`layout.html`** — adds `<link rel="icon">` for favicon, conditional robots meta
- **`home.html`** — adds `{{define "head"}}` block so home page gets SEO tags
- **New routes** — `GET /robots.txt` (renders from webapp.robotsTxt), `GET /favicon.ico` (redirects to asset)

### Handler Changes
- **`home.go`** — resolves SEO for "/" and passes to template
- **`blog.go`** — resolves SEO with blog post overrides
- **All future handlers** — call `seo.Resolve(path)` for consistent SEO

## Capabilities

### New Capabilities
- `webapp-addon`: Cockpit addon that consolidates infrastructure addons and provides SEO management (singleton, collection, admin screen, absorbed modules)
- `seo-resolution`: Go package that resolves SEO data for any path with caching and fallback chain
- `seo-templates`: Template components for rendering SEO meta tags, favicon, robots.txt, JSON-LD

### Modified Capabilities
- `blog-addon`: Add SEO fields to blogPosts model and SEO resolution in blog handler

## Impact

### Affected Code
- `src/addons/Webapp/` — new addon directory (PHP)
- `src/addons/Blog/Helper/Blog.php` — add SEO fields to blogPosts model
- `src/addons/AssetPathFix/` — removed (absorbed into Webapp)
- `src/addons/AssetsUpload/` — removed (absorbed into Webapp)
- `src/addons/StarterContent/` — removed (absorbed into Webapp)
- `src/addons/CachePurge/` — removed (absorbed into Webapp)
- `src/addons/CloudStorage/` — removed (absorbed into Webapp)
- `src/addons/ModelManager/` — removed (absorbed into Webapp)
- `src/templates/internal/seo/` — new Go package
- `src/templates/internal/app/app.go` — initialize seo.SEO
- `src/templates/internal/app/router.go` — add /robots.txt, /favicon.ico routes
- `src/templates/internal/handlers/home.go` — add SEO resolution
- `src/templates/addons/blog/internal/blog/blog.go` — add SEO resolution
- `src/templates/flavors/tailwind/components/seo.html` — rewritten
- `src/templates/flavors/tailwind/layout.html` — add favicon
- `src/templates/flavors/tailwind/pages/home.html` — add head block
- `src/templates/flavors/plain/components/seo.html` — rewritten
- `src/templates/flavors/plain/layout.html` — add favicon
- `src/templates/flavors/plain/pages/home.html` — add head block

### APIs
- New REST endpoints: `GET/POST/PUT/DELETE /webapp/api/seoPages` (admin CRUD)
- Existing absorbed endpoints unchanged (assets/upload, models/*, cache/purge)

### Dependencies
- No new external dependencies
- Uses existing Cockpit REST API, Redis cache, Echo router

### Sync Safety
- `internal/seo/` is in the shared template — projects get it via `gosite create`
- `gosite sync --app` respects manifest guard — project customizations preserved
- SEO data lives in Cockpit (per-project), not in Go code — no sync conflicts
