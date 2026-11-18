## 1. Sitemap hook

- [x] 1.1 `gosite.SitemapEntry`, `gosite.Sitemapper`; register the site as a provider in `New`
- [x] 1.2 Sitemap merge: seoPages, then providers, each path once; `<lastmod>` when set
- [x] 1.3 Tests: site entries with lastmod; duplicate of a seoPages path; site without the interface unchanged

## 2. Blog addon

- [x] 2.1 `/:blog/category/:slug` (filtered index, `Category` in data, 404s)
- [x] 2.2 `ReadingTime` and `Related` in the article data
- [x] 2.3 Trailing-slash routes
- [x] 2.4 Site TemplateData on blog pages (blog keys win)
- [x] 2.5 Blog sitemap provider (blogs and published articles)
- [x] 2.6 Default blog pages show reading time and related articles
- [x] 2.7 Tests for each requirement of the `blog-addon` spec

- [x] 2.8 Found on the way: a missing article (and category) answered 404 after 9 s of cache retries; not-found errors are permanent now, and `gosite.ErrNotFound` gives `CachedRender` the same 404 (gmaq's `/maquinaria/:slug`, `/proyectos/:slug`)

## 3. Release

- [x] 3.1 `core/CORE_API.md`, CHANGELOG, MIGRATIONS → 0.76.0, version 0.76.0
- [ ] 3.2 PR, green CI, merge, tags `v0.76.0` + `core/v0.76.0`, release with assets, usual checks
