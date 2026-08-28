## Context

The gosite scaffold currently has 6 small Cockpit addons (AssetPathFix, AssetsUpload, StarterContent, CachePurge, CloudStorage, ModelManager) that are independent infrastructure pieces with no admin UI. Additionally, SEO support is minimal — the `seo.html` template only works for blog pages, the home page has zero SEO tags, and there's no way to configure site-wide metadata or per-page overrides.

The Go app reads CMS data via REST API and renders templates with Echo. The current architecture uses a `mountFeatures` pattern for optional addons (blog) and a cache-aside pattern over Redis.

**Stakeholders:**
- Content editors: need admin UI to manage SEO per page
- Developers: need consistent SEO resolution across all handlers
- AI/LLM crawlers: need structured content via `llmText` field
- Search engines: need proper meta tags, JSON-LD, robots.txt

## Goals / Non-Goals

**Goals:**
1. Single `Webapp` addon consolidating 6 infrastructure addons + SEO management
2. Admin screen visible in sidebar (like Blog, Analytics, Forms, Replica) with:
   - Top section: SEO configuration (singleton fields)
   - Bottom section: SEO pages collection
3. Unified SEO resolution for ALL pages (not just blog)
4. Blog articles get their own SEO fields (co-located with content)
5. Proper fallback chain: content overrides → seoPages → webapp defaults
6. Redis caching for SEO lookups (TTL 5min)
7. New routes: `/robots.txt`, `/favicon.ico`
8. Support for JSON-LD structured data

**Non-Goals:**
- Sitemap.xml generation (future work)
- RSS feed generation (out of scope per blog design)
- Analytics dashboard in webapp addon (stays in Analytics addon)
- Content replication changes (Replica addon unchanged)
- Form submission management (Forms addon unchanged)

## Decisions

### Decision 1: SEO resolution in Go package, not in templates

**Choice:** Create `internal/seo/` package with `Resolve()` function.

**Alternative considered:** Template functions that call Cockpit directly.

**Why:** 
- Templates shouldn't make HTTP calls (separation of concerns)
- Redis caching needs to be centralized (singleflight dedup)
- Testing is easier with a package than template functions
- All handlers get the same resolution logic without code duplication

### Decision 2: Blog SEO fields on blogPosts, not in seoPages collection

**Choice:** Add `seoTitle`, `seoDescription`, `seoImage`, `seoJsonLd`, `seoCanonical`, `seoNoIndex` fields to `blogPosts` model.

**Alternative considered:** Store blog SEO in seoPages collection with path="/{blog}/{slug}".

**Why:**
- SEO data co-located with content (editor sees it while editing)
- No duplication — don't need to create seoPages entry for every blog post
- Fallback chain is natural: seo fields → excerpt/cover → defaults
- Reduces admin overhead for content creators

### Decision 3: Webapp addon as built-in, not optional

**Choice:** Always install Webapp addon (like the 6 it absorbs).

**Alternative considered:** Make it optional like Blog.

**Why:**
- SEO is fundamental to every website, not optional
- robots.txt and favicon are required for any production site
- The absorbed addons (CachePurge, CloudStorage, etc.) are infrastructure that every project needs

### Decision 4: Absorbed addons as module files, not separate namespaces

**Choice:** Each absorbed addon becomes a PHP file in `Webapp/modules/`.

**Alternative considered:** Move entire addon directories under Webapp namespace.

**Why:**
- Simpler — no namespace changes needed
- Each module is a single file (most are <50 lines)
- bootstrap.php includes them all at once
- Functionality identical, just organizational change

### Decision 5: SEO caching in Redis with 5min TTL

**Choice:** Cache resolved SEO data in Redis with 5min TTL, invalidated on content save.

**Alternative considered:** No caching (query Cockpit on every request).

**Why:**
- SEO data changes infrequently (once per page edit)
- 5min TTL is acceptable stale window
- Redis already available (used for cache-aside pattern)
- Matches existing cache architecture in the app

### Decision 6: Admin CRUD for seoPages via existing Cockpit pattern

**Choice:** Use Cockpit's built-in collection CRUD for seoPages, expose via admin API.

**Alternative considered:** Custom storage (separate MongoDB collection).

**Why:**
- Leverages Cockpit's existing content management
- Editors can also manage seoPages via Cockpit's Content editor
- No custom storage layer needed
- Consistent with how blogPosts, analyticsIntegrations work

## Risks / Trade-offs

### Risk 1: Absorbing 6 addons increases Webapp complexity
**Mitigation:** Each module is independent and self-contained. Modules are loaded via `include()` in bootstrap.php. Removing a module is deleting the file and its hooks.

### Risk 2: SEO resolution adds latency to every page render
**Mitigation:** Redis caching with singleflight dedup. Cold render takes ~100ms (Cockpit REST call), subsequent renders are cache hits (~1ms). Cache invalidated on content save via existing CachePurge hook.

### Risk 3: Blog SEO fields increase blogPosts model complexity
**Mitigation:** Fields are optional — if empty, fallback chain kicks in. Existing blog posts are unaffected (new fields default to empty). Admin UI shows SEO fields in a separate section.

### Risk 4: `internal/seo/` package in template could drift from project customizations
**Mitigation:** Manifest guard in `gosite sync --app` detects and preserves project edits. Package is designed to be extensible (custom resolvers can be added).

### Risk 5: robots.txt is static (no per-path rules)
**Mitigation:** robots.txt is inherently site-wide. Per-path control is via `noIndex` meta tag in seoPages/blogPosts. Future: could add conditional rules based on path patterns.

## Migration Plan

### Phase 1: Create Webapp addon (Cockpit side)
1. Create `src/addons/Webapp/` with bootstrap.php, Helper, Controller, views
2. Create webapp singleton and seoPages collection in ensureModels()
3. Move absorbed addon code into Webapp/modules/
4. Remove original addon directories
5. Update `cmd_create.sh` to install Webapp instead of 6 individual addons

### Phase 2: Create SEO package (Go side)
1. Create `src/templates/internal/seo/seo.go` with Data, WebappConfig, Resolve()
2. Add SEO initialization in app.go
3. Add /robots.txt and /favicon.ico routes in router.go

### Phase 3: Update templates
1. Rewrite `seo.html` component for full SEO support
2. Update `layout.html` with favicon and robots meta
3. Update `home.html` with head block

### Phase 4: Update handlers
1. Update home.go to resolve SEO
2. Update blog.go to resolve SEO with post overrides
3. Add SEO fields to blogPosts model in Blog addon

### Rollback
- Revert addon changes: restore original 6 addon directories
- Revert Go package: delete `internal/seo/`
- Revert template changes: restore original seo.html, layout.html, home.html
- No data loss — Cockpit models (webapp, seoPages) can remain without affecting functionality

## Open Questions

1. Should the webapp singleton include a `siteName` field for `<meta property="og:site_name">`?
2. Should seoPages support a `locale` field for multi-language SEO?
3. Should the admin screen show a preview of how SEO tags will render?
4. Should the absorbed addons' event hooks be namespaced under `webapp.*` or keep their original event names?
