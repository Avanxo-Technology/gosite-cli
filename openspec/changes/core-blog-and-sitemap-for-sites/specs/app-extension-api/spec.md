## ADDED Requirements

### Requirement: Sites add sitemap entries
The core SHALL detect an optional `Sitemapper` interface on the `App` (`SitemapEntries(ctx context.Context) []SitemapEntry`, where `SitemapEntry` has `Path` and `LastMod`), and `/sitemap.xml` SHALL list the site's entries after the `seoPages` entries, with `<lastmod>` when `LastMod` is set, and SHALL list a path only once.

#### Scenario: Dynamic catalog pages
- **WHEN** a site's `SitemapEntries` returns `/maquinaria/cat-320` with a last-modified time
- **THEN** `/sitemap.xml` has that URL with that `<lastmod>`

#### Scenario: Path already in seoPages
- **WHEN** a site returns a path that `seoPages` also lists
- **THEN** the URL appears once, as `seoPages` lists it

#### Scenario: Site without the interface
- **WHEN** an `App` does not implement `Sitemapper`
- **THEN** `/sitemap.xml` is the same as before this change
