## Context

gosite ships Cockpit addons from `src/addons/` into every scaffold, and
`gosite sync --addons <name>` installs them into projects that already exist.
`Forms` is the reference implementation: a helper holding the business logic,
`ensureModels()` creating its content models on first admin load, an admin
screen, and its own controllers.

A blog uses the same distribution channel but inverts the data flow. Form data
arrives from the public site and the admin screen is the product; blog content
is authored in Cockpit's own Content editor and the product is the pages the Go
app serves. The consequence is that most of the work lands on the Go side,
where today there is very little to build on:

- `internal/cms` exposes only `Singleton()`. No collection read exists.
- `internal/cache` purges named keys. There is no group purge.
- `internal/app/router.go` is documented as *"the single source of truth for the
  app's HTTP surface — nothing registers routes anywhere else"*, and `sync`'s
  manifest deliberately preserves files the project has edited.
- `internal/views/render.go` embeds `pages/*.html`, so new page templates are
  picked up with no registration.

Two behaviours of Cockpit's core REST API, documented in
`src/addons/Replica/Helper/Client.php`, shape this design:

1. Every read endpoint hard-codes `filter._state = 1`, so unpublished entries
   are invisible to the API (`Client.php:23`).
2. `GET /api/content/items/{model}` returns a bare array, but returns
   `{data, meta}` when `skip` **and** `limit` are both present. Reading the
   wrapper as a list yields two items with no `_id` (`Client.php:199-207`).

## Goals / Non-Goals

**Goals:**

- One content schema, identical in every project, so a blog bug is fixed once.
- Several blogs per site without creating models per blog.
- Blog pages served from the same cache-aside path as the home page.
- Installable into the five existing projects without hand-editing their Go
  source or clobbering files they own.

**Non-Goals:**

- Draft preview from the CMS. The core read API cannot serve unpublished
  entries, so this would require the addon to expose its own authenticated read
  endpoint. Deferred deliberately; the design leaves room for it.
- RSS, comments, related-posts, full-text search.
- Replacing Cockpit's Content editor. Authoring stays there.

## Decisions

### One `blogPosts` model, with `blogs` as a backing collection

Multi-blog is data, not schema. A blog is an item in `blogs`; an article
references it.

*Alternative rejected:* one model per blog (`noticias`, `casos`), created
through the `ModelManager` addon. It gives per-blog fields and per-model ACL,
but the schema then diverges per project — which defeats the reason for
building this centrally — and the Go app would have to discover model names at
runtime.

*Alternative rejected:* a plain text discriminator field, as `formSubmissions`
uses for `form`. A reference to a real `blogs` collection costs the same and
gives the blog a name, a slug and a description without a second config model.

### Model names are prefixed

`blogs`, `blogPosts`, `blogCategories`, `blogAuthors`, all with
`'group' => 'Blog'`.

`categories` and `authors` are names a client is likely to want for their own
content. Because `ensureModels()` skips a model that already exists, a
collision would be **silent**: the addon would find `categories`, leave it
alone, and the blog would start reading product categories. Prefixing follows
what `Forms` already does with `formSubmissions` / `formSettings`.

The model name and the URL are independent: routes stay `/{blog}/{slug}`.

### URLs are `/{blog}` and `/{blog}/{slug}`

Chosen over a single `/articles` index. Each blog gets its own index, which is
what a client running two unrelated blogs expects, and it reads better for SEO.

The cost is that the blog route sits at the root of the site, where every other
page lives. Two mitigations, both specified:

- Blog slugs are validated against the paths the scaffold reserves (`static`,
  `storage`, `healthz`, `cache`, `api`) and refused at save time in the CMS.
- Route precedence puts concrete paths ahead of the blog parameter, so a
  project page at `/contacto` wins over a blog with slug `contacto`. Verified by
  test against echo v5.3.1: a static segment wins over `:param` at the same
  depth **regardless of registration order**, so the URL choice is safe and the
  route-per-blog fallback is not needed.

### Slugs are unique per blog, enforced by the addon

Follows from the URL shape: the blog segment already disambiguates. Two blogs
can each have `novedades`.

Cockpit's own `meta.unique` cannot express this. `isContentUnique()` builds an
`$or` across the whole collection with no scoping by another field, so
`meta.unique = 'slug'` would mean *globally unique across the model* — which
contradicts the URL choice. The scoped check therefore lives in the addon, on
`content.item.save.before.blogPosts`.

Slug generation transliterates accents (`diseño` → `diseno`). Collisions within
a blog are refused or suffixed at save time, never silently accepted — a
duplicate slug means one of the two articles becomes unreachable.

### The byline falls back to `_cby`, resolved server-side

`content->saveItem()` already stamps the acting user on every save — as
`_cby` (creator) and `_mby` (last modifier), **not** `_by` as this design first
assumed; verified in core 2.14.0 and recorded in
`src/knowledge/cockpit-collection-reads.md`. `Forms/Helper/Forms.php:346-347`
passes `['user' => null]` precisely to suppress the stamp for anonymous
submissions. So "the author is the logged-in user" needs no new field; the
byline falls back to `_cby`.

But `_cby` is audit metadata and a byline is content: an agency employee
publishes on behalf of a client, guest authors have no CMS account, and a
byline needs a photo and a bio that a user account does not have. So the
article carries a `blogAuthors` reference, and when it is empty the byline
falls back to the `blogAuthors` item linked to `_cby`.

*Alternative rejected:* pre-filling the author field in the Cockpit editor when
a post is created. That requires hooking Cockpit's Vue admin UI from an addon,
which is unverified and far more fragile than resolving the fallback at render
time.

Whichever side resolves the fallback must expose only display fields. Cockpit
users are Avanxo staff accounts; their e-mail addresses must not reach a public
response.

### The collection read forces the wrapper shape

Every collection read sends `skip` and `limit`, so Cockpit always returns
`{data, meta}` and the shape is deterministic. This is not only defensive:
without those parameters there is no `meta`, and without `meta` there is no
total to paginate with. Forcing the shape and getting the total are the same
act.

The decoder still tolerates both shapes — the rule is deduced from one Cockpit
version and is not documented by upstream — normalising into a single result
type carrying items and a total. Callers never see the branch.

`meta.total` is an exact count of everything matching the filter, so an exact
page count is available. The spec still requires paging to work without a
total — requesting `limit + 1` and inferring the next page from the extra item
— so a future Cockpit dropping `meta` degrades rather than breaks.

### Drafts are handled by doing nothing

`filter._state = 1` is enforced by Cockpit, not by our filter. This is
fail-safe: no bug in our query can leak a draft, because the API will not
return one. The `_state` field already drives Cockpit's own published/unpublished
UI, so editors get the workflow for free.

### The blog mounts from its own package

`internal/blog` owns the handlers, the cache keys and the route registration,
exposing a single mount function. `router.go` gains one line.

*Alternative rejected:* patching `router.go` with the installer. The file is
routinely hand-edited and `sync` preserves it by design; a patcher would be
fighting the manifest.

*Alternative rejected:* self-registration via `init()`. It works, but a route
that appears with no visible call contradicts the router's stated role as the
single source of truth for the HTTP surface.

When the installer cannot insert the mount line safely it finishes everything
else and prints the exact line and its location. One manual line is a better
failure mode than a corrupted router.

### Cache keys are namespaced so a group can be purged

```
__PROJECT__:home_html                    unchanged
__PROJECT__:blog:{blog}:index:{page}     one per index page
__PROJECT__:blog:{blog}:post:{slug}      one per article
```

Publishing an article purges its own key and every index key of its blog, since
a new article changes what the index lists. Other blogs and the home page are
untouched.

The purge endpoint keeps its current authentication and fail-closed behaviour
unchanged — v0.43.0 closed that hole and this change must not reopen it.

## Risks / Trade-offs

- **Relations are stored as references, not documents.** A `contentItemLink`
  field holds `{_model, _id}`, so every rendered page needs `populate` with a
  depth, and the payload grows with it. → Use `fields` projection on the index
  so the list does not drag full article bodies over the wire.
- **Root-level blog routes could shadow site pages.** A client adding
  `/contacto` later, or a blog slug matching an existing path. → Reserved-slug
  validation at save time, plus verifying echo's static-over-param precedence
  before wiring. Fallback: register one route per blog at boot.
- **Slug changes break links permanently.** Editing a published slug orphans
  every existing link to it. → Out of scope to solve now; note it in the addon
  README so the behaviour is at least known, and leave room for a redirect map.
- **Pattern purge on Redis is a scan.** Purging a group by key pattern is more
  expensive than deleting a known key. → Blogs are small and purges are rare
  (an editor publishing), but the implementation should avoid blocking the
  server on a large keyspace.
- **Five projects on three different addon versions.** Four projects still run
  the pre-0.43.0 Forms addon, so their addon trees are already behind.
  → The blog install is independent of that; do not bundle the two migrations.
- **Scope creep from "blog".** Clients asking for a blog usually mean SEO.
  Metadata and canonical URLs are in scope for that reason; RSS and sitemap are
  not, and that boundary should be stated to the client rather than discovered
  later.

## Migration Plan

1. Spike the three unverified Cockpit behaviours against a running instance.
2. Build the addon and the Go side in the base repo; new scaffolds get it for
   free.
3. Install into **one** project first — ba-pow, which is already on 0.43.1 and
   was created recently, so it carries the least risk.
4. Rebuild that project's CMS image and application, and verify the pages
   against the specs.
5. Roll out to the remaining four only after they are migrated to the current
   addon baseline, keeping the two migrations separate so a failure is
   attributable.

Rollback is per project: the blog is additive. Removing the mount line and
rebuilding restores the previous HTTP surface; the content models can stay in
place unread.

## Open Questions

Resolved by the task-1 spike against Cockpit core 2.14.0 and echo v5.3.1, and
recorded in `src/knowledge/cockpit-collection-reads.md`:

- Relations are `contentItemLink`, with `opts.link` naming the target model.
- Authorship is `_cby` / `_mby`, holding user **ids**.
- `meta` carries `total` — an exact count of everything matching the filter.
- echo prefers a static segment over `:param` regardless of registration order,
  confirmed by test, so the `/{blog}` URL shape is safe and the
  route-per-blog fallback is not needed.
- `filter`, `sort` and `fields` are JSON5 **strings**, not nested query params.

Still open:

- Should the blog's public base URL live in `.env` or in the CMS, given the
  admin screen needs it to build preview links?
- Which field type for the article body — `wysiwyg` or `code`/markdown? Affects
  how the Go templates escape it.
