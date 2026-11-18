## Why

gmaq-dev is the next legacy site to move to thin (#49), and it uses three things core lacks:
- Its sitemap lists every machine, project and rental process from the CMS, with their modification dates. Core builds the sitemap only from `seoPages`, which cannot hold content that editors add every week.
- Its blog has category pages, related articles, a reading time and URLs with a trailing slash (kept from the WordPress site it replaced), and its blog pages carry the site's header and footer.
- Its blog index and articles are in `sitemap.xml`.

Core's blog addon has none of these. The owner decided (2026-11-18) to add them to core instead of keeping them in the site, so every thin site gets them.

## What Changes

- **New optional interface `gosite.Sitemapper`** (`SitemapEntries(ctx) []gosite.SitemapEntry`, with a path and a last-modified time). Core adds the site's entries to `sitemap.xml` after the `seoPages` entries; a path already listed is not repeated.
- **Blog addon (core):**
  - `GET /:blog/category/:slug`: the blog index filtered by one category (`blogCategories`). It answers 404 for an unknown blog or category.
  - The article page gets `ReadingTime` (minutes, at least 1) and `Related` (up to 3 published articles of the same category, newest first, the article itself excluded).
  - Every blog route also answers with a trailing slash, with the same content.
  - Blog pages get the site's `TemplateData`, under the blog's own keys.
  - The blog index of every blog and each published article are in `sitemap.xml`, with the article's last-modified time.
- Version 0.76.0, a minor release: the public API grows.

## Capabilities

### New Capabilities
- `blog-addon`: the core blog's routes and the data its pages get.

### Modified Capabilities
- `app-extension-api`: a site can add sitemap entries.

## Impact

- `core/gosite.go`, `core/internal/seo` (sitemap merge), `core/internal/handlers/sitemap.go`, `core/internal/addons/blog`, `core/CORE_API.md`.
- The blog's default pages (`core/internal/addons/blog/pages/`) show the reading time and the related articles when present.
- Sites with a blog get the extra routes and sitemap entries after `gosite upgrade`. A theme that overrides the blog pages is unchanged, and the new keys are only additional data.
