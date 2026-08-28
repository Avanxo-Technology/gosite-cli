// Package blog serves the public blog pages: an index per blog at /{blog} and
// an article at /{blog}/{slug}.
//
// It owns everything about the blog on this side - its routes, its cache keys
// and its cache invalidation - so the rest of the application needs exactly one
// line to gain a blog, and loses it again by deleting that line. Content comes
// from the Cockpit models the Blog addon installs.
//
// Drafts never appear here. Cockpit's read API only ever returns published
// entries, so an unpublished article is not filtered out by this package - it
// is never delivered to it.
package blog

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/labstack/echo/v5"

	"__MODULE__/internal/cms"
	"__MODULE__/internal/handlers"
)

// Cockpit models installed by the Blog addon.
const (
	modelBlogs = "blogs"
	modelPosts = "blogPosts"
)

// perPage is how many articles an index page lists.
const perPage = 10

// populateDepth resolves contentItemLink references - author, category - into
// documents. Without it they arrive as {_model, _id} and rendering a byline
// would cost one extra CMS call per article.
const populateDepth = 1

// Blog is the mounted feature: its dependencies plus the routes it serves.
type Blog struct {
	handlers.Deps

	// h is kept so the blog answers with the same cache header, error page and
	// logging as every other route rather than reinventing them.
	h *handlers.Handlers
}

// Mount registers the blog's routes and its cache invalidation.
//
// Route precedence makes this safe to mount at the root: echo resolves a
// concrete path segment before `:blog`, in either registration order, so a page
// the project serves at /contacto keeps winning over a blog whose slug is
// "contacto". The addon refuses to save a blog slug matching a path the
// scaffold reserves, so the two halves agree.
func Mount(e *echo.Echo, h *handlers.Handlers) *Blog {
	b := &Blog{Deps: h.Deps, h: h}

	e.GET("/:blog", b.Index)
	e.GET("/:blog/:slug", b.Article)

	h.OnPurge(b.purge)

	return b
}

// --------------------------------------------------------------- cache keys

// keyPrefix namespaces every key this package owns, so the group can be purged
// without naming each page.
func keyPrefix() string { return "__PROJECT__:blog:" }

func blogPrefix(blogSlug string) string { return keyPrefix() + blogSlug + ":" }

func indexKey(blogSlug string, page int) string {
	return blogPrefix(blogSlug) + "index:" + strconv.Itoa(page)
}

func articleKey(blogSlug, slug string) string {
	return blogPrefix(blogSlug) + "post:" + slug
}

// ------------------------------------------------------------------- routes

// Index serves /{blog} - the articles of one blog, newest first, paginated.
func (b *Blog) Index(c *echo.Context) error {
	blogSlug := c.Param("blog")

	page := 1
	if raw := c.QueryParam("page"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 {
			return echo.ErrNotFound
		}
		page = parsed
	}

	// Resolving the blog before touching the cache keeps an unknown slug from
	// creating cache entries, which would otherwise let anyone fill Redis by
	// requesting random paths.
	blogDoc, err := b.lookupBlog(c.Request().Context(), blogSlug)
	if err != nil {
		return b.fail(c, err)
	}
	if blogDoc == nil {
		return echo.ErrNotFound
	}

	html, cached, err := b.Cache.HTML(c.Request().Context(), indexKey(blogSlug, page), func() ([]byte, error) {
		return b.renderIndex(blogDoc, blogSlug, page)
	})
	if err != nil {
		if err == errNotFound {
			return echo.ErrNotFound
		}
		return b.fail(c, err)
	}

	return b.page(c, html, cached)
}

// Article serves /{blog}/{slug}.
func (b *Blog) Article(c *echo.Context) error {
	blogSlug, slug := c.Param("blog"), c.Param("slug")

	blogDoc, err := b.lookupBlog(c.Request().Context(), blogSlug)
	if err != nil {
		return b.fail(c, err)
	}
	if blogDoc == nil {
		return echo.ErrNotFound
	}

	html, cached, err := b.Cache.HTML(c.Request().Context(), articleKey(blogSlug, slug), func() ([]byte, error) {
		return b.renderArticle(blogDoc, blogSlug, slug)
	})
	if err != nil {
		if err == errNotFound {
			return echo.ErrNotFound
		}
		return b.fail(c, err)
	}

	return b.page(c, html, cached)
}

// errNotFound distinguishes "this article does not exist" from "the CMS is
// broken". Only the second is worth a 502, and only the second must keep the
// cache from storing the render.
var errNotFound = fmt.Errorf("not found")

// ------------------------------------------------------------------ renders

// renderIndex builds one page of a blog index.
//
// Like the home page it uses its own context rather than the request's: a cold
// render is shared by every request waiting on it, so one caller disconnecting
// must not cancel work the others are waiting for.
func (b *Blog) renderIndex(blogDoc cms.Content, blogSlug string, page int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	res, err := b.CMS.Items(ctx, modelPosts, cms.Query{
		Filter:   map[string]any{"blog._id": blogDoc["_id"]},
		Sort:     map[string]int{"publishedAt": -1},
		Skip:     (page - 1) * perPage,
		Limit:    perPage,
		Populate: populateDepth,
		// The index lists titles and excerpts; dragging every article body
		// across the network to render them is pure waste.
		Fields: map[string]int{"title": 1, "slug": 1, "excerpt": 1, "cover": 1, "publishedAt": 1, "author": 1, "category": 1},
	})
	if err != nil {
		return nil, err
	}

	// An empty first page is a blog nobody has written in yet, which is a real
	// page. An empty later page is a URL past the end, which is a 404.
	if len(res.Items) == 0 && page > 1 {
		return nil, errNotFound
	}

	title := str(blogDoc["title"])
	path := "/" + blogSlug

	data := map[string]any{
		"Title":   title,
		"Path":    path,
		"Blog":    blogDoc,
		"Posts":   res.Items,
		"Page":    page,
		"HasMore": res.HasMore,
		"PrevURL": pageURL(path, page-1),
		"NextURL": pageURL(path, page+1),
		"Total":   res.Total,
		"Meta":    b.meta(title, str(blogDoc["description"]), path, nil),
		"IsDev":   b.Config.IsDev(),
	}

	var buf bytes.Buffer
	if err := b.Renderer.Page(&buf, "blog-index", data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// renderArticle builds one article page.
func (b *Blog) renderArticle(blogDoc cms.Content, blogSlug, slug string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	post, err := b.CMS.First(ctx, modelPosts, map[string]any{
		"slug":     slug,
		"blog._id": blogDoc["_id"],
	}, populateDepth)
	if err != nil {
		return nil, err
	}
	if post == nil {
		// Either it does not exist or it is not published. The CMS does not
		// distinguish the two and neither should the site: both are 404.
		return nil, errNotFound
	}

	title := str(post["title"])
	path := "/" + blogSlug + "/" + slug

	data := map[string]any{
		"Title":   title,
		"Path":    path,
		"Blog":    blogDoc,
		"Post":    post,
		"Author":  asDoc(post["author"]),
		"SEOData": b.seoData(post),
		"Meta":    b.meta(title, str(post["excerpt"]), path, post["cover"]),
		"IsDev":   b.Config.IsDev(),
	}

	var buf bytes.Buffer
	if err := b.Renderer.Page(&buf, "blog-article", data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ------------------------------------------------------------------ helpers

// lookupBlog resolves a blog slug to its document, or nil when there is none.
func (b *Blog) lookupBlog(ctx context.Context, slug string) (cms.Content, error) {
	if slug == "" {
		return nil, nil
	}
	return b.CMS.First(ctx, modelBlogs, map[string]any{"slug": slug}, 0)
}

// meta is what the templates need for the document head. Canonical and Open
// Graph URLs are absolute because crawlers require it; with no configured site
// URL they are empty and the templates omit those tags rather than emit a
// relative value that would be read as wrong.
func (b *Blog) meta(title, description, path string, cover any) map[string]any {
	canonical := ""
	if b.Config.SiteURL != "" {
		canonical = b.Config.SiteURL + path
	}

	image := ""
	if p := assetPath(cover); p != "" {
		image = b.Config.AssetBaseURL() + p
		// Open Graph images must be absolute too. A relative asset base means
		// the assets are served by this site, so the site URL completes it.
		if !strings.HasPrefix(image, "http") && b.Config.SiteURL != "" {
			image = b.Config.SiteURL + image
		} else if !strings.HasPrefix(image, "http") {
			image = ""
		}
	}

	return map[string]any{
		"Title":       title,
		"Description": description,
		"Canonical":   canonical,
		"Image":       image,
	}
}

// seoData creates SEO overrides from a blog post's SEO fields.
// assetURL joins the asset base with a Cockpit asset path.
//
// Neither side carries the separator - AssetBaseURL is trimmed of its trailing
// slash and an asset path has no leading one - so joining them by concatenation
// produced ".../assets2026/08/28/x.png". With local storage the result is a
// site-root path, which SiteURL then makes absolute for og:image.
func (b *Blog) assetURL(path string) string {
	url := strings.TrimRight(b.Config.AssetBaseURL(), "/") + "/" + strings.TrimLeft(path, "/")
	if !strings.HasPrefix(url, "http") && b.Config.SiteURL != "" {
		url = strings.TrimRight(b.Config.SiteURL, "/") + url
	}
	return url
}

func (b *Blog) seoData(post cms.Content) map[string]any {
	if post == nil {
		return nil
	}

	// A post is an article, not the site. Set before the overrides so a post
	// that declares its own type still wins.
	data := map[string]any{"type": "article"}

	// SEO title: override falls back to article title
	if v := str(post["seoTitle"]); v != "" {
		data["title"] = v
	} else if v := str(post["title"]); v != "" {
		data["title"] = v
	}

	// SEO description: override falls back to excerpt
	if v := str(post["seoDescription"]); v != "" {
		data["description"] = v
	} else if v := str(post["excerpt"]); v != "" {
		data["description"] = v
	}

	// SEO image: override falls back to cover
	if v := assetPath(post["seoImage"]); v != "" {
		data["image"] = b.assetURL(v)
	} else if v := assetPath(post["cover"]); v != "" {
		data["image"] = b.assetURL(v)
	}

	// JSON-LD
	if v := str(post["seoJsonLd"]); v != "" {
		data["jsonLd"] = v
	}

	// Canonical override
	if v := str(post["seoCanonical"]); v != "" {
		data["canonical"] = v
	}

	// NoIndex
	if v, ok := post["seoNoIndex"].(bool); ok && v {
		data["noIndex"] = true
	}

	return data
}

// purge invalidates what an edit in the CMS changed.
//
// A new article changes its blog's index as well as its own page, so the whole
// blog is dropped rather than the single article. When the changed item cannot
// be resolved to a blog - which is exactly what happens when an article is
// unpublished, since the CMS stops serving it - every blog is dropped instead.
// Over-purging costs a re-render; under-purging serves content that no longer
// exists.
func (b *Blog) purge(ctx context.Context, model, id string) error {
	switch model {
	case modelPosts, modelBlogs, "blogCategories", "blogAuthors":
	case "":
		// Nothing named: the on-page button, or a CMS that does not send a
		// body. Purging every blog page is the safe reading of "purge".
		return b.Cache.PurgeGroup(ctx, keyPrefix())
	default:
		// Some other model changed, and it is not one whose content reaches
		// these pages.
		//
		// Content that IS on every page - analytics keys, anything the layout
		// carries - never arrives here: the purge handler recognises those and
		// drops the whole project before any hook runs. So this branch only
		// ever sees models that genuinely change nothing here, and keeping the
		// pages matters: a public form submission is a content save too, and
		// dropping the blog's cache on every one of them would be expensive
		// and pointless.
		return nil
	}

	if model == modelPosts && id != "" {
		if slug := b.blogSlugOfPost(ctx, id); slug != "" {
			return b.Cache.PurgeGroup(ctx, blogPrefix(slug))
		}
	}

	return b.Cache.PurgeGroup(ctx, keyPrefix())
}

// blogSlugOfPost resolves the blog an article belongs to. Returns "" when the
// article cannot be read, which includes the case of it having just been
// unpublished.
func (b *Blog) blogSlugOfPost(ctx context.Context, id string) string {
	post, err := b.CMS.First(ctx, modelPosts, map[string]any{"_id": id}, populateDepth)
	if err != nil || post == nil {
		return ""
	}
	if blogDoc := asDoc(post["blog"]); blogDoc != nil {
		return str(blogDoc["slug"])
	}
	return ""
}

func (b *Blog) fail(c *echo.Context, err error) error {
	return b.h.Reply(c).Fail(http.StatusBadGateway, "could not load the page", err)
}

func (b *Blog) page(c *echo.Context, html []byte, cached bool) error {
	return b.h.Reply(c).Page(html, cached)
}

// pageURL builds an index page link, or "" when the page number is out of
// range so the template can omit the link entirely.
func pageURL(path string, page int) string {
	if page < 1 {
		return ""
	}
	if page == 1 {
		return path
	}
	return path + "?page=" + strconv.Itoa(page)
}

// asDoc reads a populated contentItemLink. With populate the reference becomes
// the target document; without it, it stays {_model, _id} and there is nothing
// to display, which is treated the same as absent.
func asDoc(value any) cms.Content {
	doc, ok := value.(map[string]any)
	if !ok {
		return nil
	}
	if len(doc) <= 2 {
		if _, hasModel := doc["_model"]; hasModel {
			return nil
		}
	}
	return cms.Content(doc)
}

// assetPath reads the path out of a Cockpit asset field, which stores an object
// describing the upload rather than a bare string.
func assetPath(value any) string {
	asset, ok := value.(map[string]any)
	if !ok {
		return ""
	}
	return str(asset["path"])
}

func str(value any) string {
	s, _ := value.(string)
	return s
}
