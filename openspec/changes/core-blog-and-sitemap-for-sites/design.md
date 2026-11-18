## Context

Taken from gmaq-dev's legacy blog (`internal/blog/blog.go`, which grew past the gosite template) and its sitemap providers (`internal/handlers/sitemap_*.go`). Core's sitemap handler already merges extra entries from registered providers (`h.OnSitemap`); the blog addon and the App just do not use that.

## Decisions

- **Sitemapper is an optional interface**, like `Purger` and `TemplateDataer`, detected in `gosite.New`, registered as a sitemap provider. `gosite.SitemapEntry` is a public struct mirroring `seo.SitemapEntry`, so `internal/seo` stays internal.
- **Order and duplicates:** seoPages first (the editor's declaration wins), then providers in registration order (the site's, registered in `New`, then the blog's, registered when it mounts), each path once.
- **Category pages** reuse the index render with a category filter (`category._id`), cached through the blog's own key family, so the blog purge hook covers them.
- **Reading time and Related** are computed in the article render, the same way gmaq does (words outside tags / 200, rounded up; Related: 3, same category, `publishedAt` descending, `_id` excluded). A failure to read Related logs and leaves it empty: the article still renders.
- **Trailing slash:** the routes are registered twice (Echo matches exactly), because a redirect would change what an old link answers.
- **TemplateData on blog pages:** the blog renders through a hook core gives it (the server's template data function) and merges its own keys over it. It is called with the blog page's name.
- **Blog sitemap:** a provider in the addon lists every blog (`/<slug>`) and its published articles (`/<blog>/<slug>`, `_modified` as LastMod), limited to 1,000 articles per blog.

## Risks

- A site whose theme has its own `/:blog/category/:slug` route keeps it: site routes win.
- Sitemap size: 1,000 articles per blog is far above any current site.
