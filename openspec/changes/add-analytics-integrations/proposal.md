## Why

Client sites need third-party JavaScript: Google Tag Manager today, PostHog
next, and more tools over time — each needing a key or an ID, in the document
head, the body, or both.

There is nowhere to put them. The only option today is editing each project's
`layout.html` by hand, which means five layouts drifting apart, a release for
every key change, and no way for a client to add their own tag without asking
Avanxo for a deploy.

Doing it once in the base is the same argument the blog made: five sites
running the same mechanism, so a bug is fixed once.

## What Changes

- **A new `Analytics` Cockpit addon** holding the keys as content, not
  configuration. One collection, one entry per integration:
  `provider` (a select over what the site knows how to render), `config`
  (an object — GTM needs an id, PostHog needs a key and a host, the next tool
  will need something else), `enabled`, and the environments it applies to.
  Adding a key is data. Adding a *kind* of tool stays a visible change to the
  base, because something has to know how to render it.
- **The scripts are `analytics` plugins**, not hand-written snippets. The core
  loads from a pinned CDN URL; the plugins live in the base templates under
  `static/js/analytics/`. None of the official plugins ship a browser bundle,
  so each provider gets a small plugin of our own — which is roughly the work a
  hand-written snippet would have been, plus a uniform `track` / `page` /
  `identify` API across every provider and one place to switch everything off.
- **A template component renders it**, in two blocks: one for the head and one
  for the body, because GTM needs both. Which block a provider uses is the
  partial's business, not the editor's.
- **Keys reach the page as data, never as code.** A JSON block the local
  script reads, so no CMS value is ever interpolated into JavaScript and a
  malformed one fails a `JSON.parse` instead of executing.
- **The keys reach the templates through a template function**, the way
  `assetURL` already does, so no handler has to remember to pass them and no
  page can silently lose its tracking.
- **A change to site-wide settings purges the whole project's cache.** Today
  invalidation assumes an edit affects one area; these keys are in the layout
  of every page.

Explicitly out of scope, deliberately:

- **Consent management.** A separate task. This design must not preclude it —
  the single mount point in `init.js` is where it will hook — but no cookie
  banner, no consent mode and no deferred loading ship here.
- **Server-side events.** PostHog has a backend SDK and it is more reliable
  than anything in the browser, but it is a different mechanism with a
  different data path.
- **A proxy for PostHog** to survive ad blockers. Worth doing later — this
  stack already proxies `/storage/uploads`, so the pattern exists — but it is
  not needed to load a script.

## Capabilities

### New Capabilities

- `analytics-key-storage`: the Cockpit side — the collection, its fields, the
  provider select, validation of key formats, enabling and disabling an
  integration, and which environments an entry applies to.
- `analytics-page-integration`: the application side — how keys reach the
  templates, what the component renders into the head and the body, the
  plugin contract, environment gating, and what happens when the CMS has
  nothing to say or cannot be reached.
- `site-wide-cache-invalidation`: invalidating every cached page of a project
  when something in its layout changes, rather than only the area an edit
  belongs to.

### Modified Capabilities

None. `openspec/specs/` is empty; the `harden-gosite-phased` and
`add-blog-addon` capabilities have not been archived into it, and none of them
change here.

## Impact

**New source:**
- `src/addons/Analytics/` — bootstrap, helper, admin screen, icon
- `src/templates/static/js/analytics/` — `init.js` plus one plugin per provider
- a shared `analytics.html` component in both template flavors

**Modified source:**
- `src/templates/flavors/*/internal/views/layout.html` — two template calls
- `src/templates/internal/views/render.go` — the template function
- `src/templates/addons/blog/internal/blog/blog.go` — its purge hook returns
  `nil` for models it does not recognise, which is wrong for a model that
  changes every page
- `src/templates/internal/handlers/purge.go` — site-wide purge

**External contracts this rests on:**
- `analytics` core publishes a browser bundle at
  `unpkg.com/analytics@0.8.19/dist/analytics.min.js` (verified).
- Its plugin contract is a plain object; only `name` is required (verified).
- No official plugin publishes a browser bundle (verified: 404 for
  `google-tag-manager`, `google-analytics`, `simple-analytics`).

**Distribution:** the addon is baked into the CMS image, so existing projects
need a CMS rebuild. The templates are application code, so they need
`gosite sync --app` and an application rebuild.

**Version:** user-facing, so `src/VERSION` bumps and `docs/index.html` +
`README.md` need the new addon.
