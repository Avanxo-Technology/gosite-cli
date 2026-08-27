## Why

Clients are asking for blogs on their sites, and today every project would have
to invent its own: its own content models, its own URLs, its own templates. That
means five different blogs to maintain and no way to fix one bug once.

gosite already solves this shape of problem for forms — an addon in
`src/addons/` that self-installs its content models, shipped to every scaffold
and installable into existing projects with `gosite sync --addons`. A blog fits
the same distribution channel, but not the same architecture: form data flows
*into* the CMS and its admin screen is the product, while blog content flows
*out of* the CMS and the product is the two pages the Go app serves.

## What Changes

- **New `Blog` Cockpit addon** in `src/addons/Blog/`, distributed like `Forms`.
  It self-installs four content models on first admin load (`ensureModels()`),
  so a fresh install needs no manual setup:
  - `blogs` — one item per blog ("Noticias", "Casos de éxito")
  - `blogPosts` — the articles; the only model holding content
  - `blogCategories`, `blogAuthors` — reference collections
  Model names are prefixed to avoid silently colliding with a client's own
  `categories`/`authors` models, and grouped under `'group' => 'Blog'` so
  Cockpit's own sidebar clusters them.
- **An admin screen at `/blog`** that Cockpit's generic Content editor cannot
  provide: preview links to the article's real public URL on the Go site, its
  publication state at a glance, and per-post cache purge.
- **The Go CMS client learns to read collections.** `internal/cms` currently
  exposes only `Singleton()`. It gains a collection read with filter, sort,
  pagination and populate, normalising Cockpit's two response shapes.
- **Two new public pages in the scaffold**: an article index and an article
  detail addressed by slug, in both the `plain` and `tailwind` flavors.
- **Cache invalidation by pattern.** A blog is many cache keys instead of one,
  and publishing an article must invalidate both the article and the index.
- **An install path for existing projects** that adds the Go-side pages without
  overwriting a hand-edited `router.go`.

Out of scope for this change, deliberately: draft preview from the CMS (the
core read API hard-codes `filter._state = 1`, so serving a draft would require
the addon to expose its own authenticated read endpoint), RSS, and comments.

## Capabilities

### New Capabilities

- `blog-content-model`: The Cockpit-side content structure — the four models,
  their fields and relations, self-installation, slug rules, the author
  resolution rule, and the `/blog` admin screen.
- `cms-collection-reads`: The Go CMS client's collection read — filtering,
  sorting, pagination, populate depth, and normalising the bare-array vs
  `{data, meta}` response shapes into one result type.
- `blog-public-pages`: The article index and article detail pages served by the
  Go app — routing, slug resolution, 404 behaviour, pagination, and the SEO
  metadata each page emits.
- `cache-pattern-purge`: Cache invalidation across a set of related keys rather
  than a single fixed key, and which keys an article publish invalidates.
- `blog-install-existing-projects`: Installing the blog into a project that
  already exists, including how Go source is added without overwriting files
  the project owns.

### Modified Capabilities

None. `openspec/specs/` is empty — the `harden-gosite-phased` capabilities have
not been archived into it, and none of them change here.

## Impact

**New source:**
- `src/addons/Blog/` — bootstrap, admin screen, helper, models, views, icon
- `src/templates/internal/blog/` — the Go package the router mounts
- `src/templates/flavors/{plain,tailwind}/internal/views/pages/` — two pages each

**Modified source:**
- `src/templates/internal/cms/cms.go` — collection reads (additive)
- `src/templates/internal/cache/cache.go` — pattern purge (additive)
- `src/templates/internal/handlers/purge.go` — purge more than the home key
- `src/templates/internal/app/router.go` — one mount line
- `src/lib/templates.sh`, `src/commands/cmd_create.sh` — offer `Blog` in the
  addon prompt and copy the new template files
- `src/commands/cmd_sync.sh` — install the Go-side pages into existing projects
- `src/commands/cmd_doctor.sh` — optional: flag blogs with no configured base URL

**External contract this rests on** (Cockpit core, unverified in this repo and
confirmed by the first task): the field type used for relations, whether `_by`
is returned by `GET /api/content/items/`, and what `meta` contains.

**Distribution:** the addon is baked into the CMS image (`Dockerfile.cms COPY`),
so existing projects need a CMS rebuild, not a restart.

**Version:** user-facing, so `src/VERSION` bumps and `docs/index.html` +
`README.md` need the new command surface.
