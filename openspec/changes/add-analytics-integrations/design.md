## Context

Five client sites need third-party JavaScript, starting with Google Tag Manager
and PostHog and growing from there. Each tool needs a key, some need markup in
both the head and the body, and the set will keep growing.

What exists to build on:

- Addons already own their own content models and create them on first load
  (`Forms`, `Blog`, `StarterContent`). Multi-instance as data rather than
  schema is a pattern this codebase has already committed to.
- `internal/views/render.go` exposes template functions (`assetURL`,
  `safeHTML`), and pages register themselves from the embedded filesystem.
- Every third-party dependency in `layout.html` is **pinned**:
  `modern-reset@0.1.1`, `@tailwindcss/browser@4.3.3`, `htmx.org@2.0.10`,
  `alpinejs@3.15.12`. None uses subresource integrity.
- The layout has carried a note since it was written: *"Before going to
  production, vendor them into /static"*. Nobody has ever done it; `static/`
  holds only `styles.css`.
- Cache invalidation is per-area: `PurgeCache` drops the home key, and features
  register hooks for their own keys.

Facts established while exploring, by checking rather than assuming:

| | |
| --- | --- |
| `analytics` core | v0.8.19, publishes `dist/analytics.min.js` — usable from a plain `<script>` |
| its plugin contract | a plain object; only `name` is required; no imports needed |
| `@analytics/posthog` | does not exist |
| third-party PostHog plugins | `analytics-plugin-posthog` v0.0.3 (2024-01-17), `@metro-fs/...` v1.14.0 (2024-04-23) — both stale |
| official plugins' browser bundles | **nine work**, at `dist/@analytics/<name>.min.js` — an earlier check guessed the wrong filename, got 404s, and concluded there were none. Four published plugins genuinely do not work standalone |
| `html/template` in a `<script>` | escapes interpolated values as JS strings |
| dynamic template names | not supported: `{{template .Provider .}}` fails to parse |

## Goals / Non-Goals

**Goals:**

- Adding a key is data, done by whoever owns the site, with no release.
- One mechanism across five projects, so a fix lands once.
- No CMS value ever becomes executable code.
- A page cannot silently lose its tracking by being added later.

**Non-Goals:**

- **Consent management.** A separate task, by decision. The design keeps a
  single mount point where it will hook, and nothing here forecloses it.
- **Server-side events.** A different data path; more reliable, and worth doing
  for product analytics, but not this.
- **A first-party proxy for PostHog** to survive ad blockers. The stack already
  proxies `/storage/uploads`, so the pattern is there when it is wanted.
- Vendoring the library. See below.

## Decisions

### Plugins over hand-written snippets

The alternative was a template partial per provider, holding that provider's
official snippet.

The first version of this section argued the two were the same amount of work,
because "no official plugin ships a browser bundle". **That was wrong** — the
check looked for `dist/analytics-plugin-<name>.min.js` and took the 404 as
proof of absence. The real path repeats the scope
(`dist/@analytics/<name>.min.js`), and nine of the fourteen official plugins
load standalone and expose a global.

The correct comparison is much less close: with partials, every provider is
per-provider code we write and maintain. With plugins, nine providers are a
pinned URL and a global name — and only PostHog, which has no official plugin,
is ours. Adding Mixpanel or Segment is a line in a registry.

Four published plugins are unusable without a bundler and are deliberately
excluded rather than silently broken; the reasons are recorded per provider so
nobody adds them back on the assumption they were an oversight.

### Pinned CDN, not vendored

Two separate axes were being conflated: CDN versus vendored, and pinned versus
floating. What we want to avoid is a downloaded file nobody maintains; that is
solved by pinning, not by vendoring.

A floating URL (`unpkg.com/analytics/dist/...`) is rejected outright: it makes
an upstream release take effect on five client sites with no deployment,
prevents subresource integrity, and costs a redirect. It would also be the only
unpinned dependency in a codebase where all four existing ones are pinned.

Vendoring stays available as a one-line change if a strict CSP or independence
from unpkg is ever wanted — decided then, not now, and without carrying the
silent debt of an un-versioned file in the meantime.

### Keys are data, delivered as data

Configuration reaches the browser as a JSON block that the local script reads,
not interpolated into JavaScript source.

Go's contextual escaping would in fact handle interpolation correctly — verified
— but only while nobody reaches for `safeHTML`. Delivering data as data removes
the question: a value cannot execute, a malformed one fails a `JSON.parse`, and
no inline executable script is needed, which keeps a future CSP simple.

### A template function, not handler data

The alternative is each handler adding the integrations to its data map. That
makes a cross-cutting concern travel through a channel that is not, and the
failure mode is silent: a page added later loses its tracking and nobody
notices for weeks.

A template function has precedent in `assetURL` and cannot be forgotten. The
lookup happens inside the render, which is already cached with the page.

### One loader file, no per-provider template code

The component emits the configuration and two script tags; a single file,
`static/js/analytics/analytics.js`, decides from that JSON which bundles to
fetch. Adding a provider therefore touches the CMS select and that registry,
and **never a template**.

This replaced an earlier design where the component branched per provider
through a chain of comparisons — `html/template` refuses a template name from a
variable, so dispatch had to be explicit. Loading dynamically removes the
dispatch entirely. The one exception is GTM's `<noscript>` fallback, which a
script cannot supply, so it stays as the single piece of per-provider markup.

The cost is a round trip: the bundles are fetched after the loader parses,
rather than in parallel from the head. They are two to three kilobytes each,
and the alternative was per-provider template code forever.

Because page code can call `analytics.track()` before the bundles arrive, the
loader installs a queue that records those calls and replays them on mount.
Without it the first events — the ones that matter most — would throw or be
swallowed.

### A collection, with the provider constrained

Adding a key is adding an entry.

Making `provider` a select over the providers that have a plugin keeps the two
halves honest: an entry that the site cannot render cannot be saved, instead of
saving quietly and never appearing.

Configuration is an object rather than fixed fields, because providers need
different shapes and enumerating them would mean a schema change per provider.

### Head and body are the partial's decision

GTM needs a script in the head and a fallback in the body. That is a property
of GTM, not something an editor should have to know, so the component exposes
two blocks and each provider fills what it needs.

### Site-wide invalidation

These keys are in the layout, so they are on every page. Today the blog's purge
hook ends with `default: return nil` — a model it does not recognise is assumed
irrelevant. For a model that changes every page, that assumption produces
exactly the bug this feature would ship with: the home page updates and every
blog page serves the old keys for the rest of its cache window.

Invalidation needs a notion of "this changed everything", scoped to the
project — a shared Redis serves several projects, so it must not become a
flush.

## Risks / Trade-offs

- **Events lost to `loaded()`.** The library queues events until a plugin
  reports ready. Report ready too early and the first events — including the
  entry page view — vanish with no error. → The one part worth verifying by
  hand in a browser rather than by reading. Keep plugins dumb enough that this
  is the only subtle thing in them.
- **The first untested code in the scaffold.** There is no JavaScript test
  infrastructure, and standing one up for a few dozen lines is not worth it.
  → Keep the plugins free of conditionals and transformations, and verify the
  loading path manually before shipping.
- **A third copy of a flavor-agnostic component.** `seo.html` is already
  duplicated across `plain` and `tailwind` with identical content; this adds
  `analytics.html`. Two files that must stay in step, and nothing enforces it.
  → Note it. A shared components directory outside the flavors is worth
  considering, but not inside this change.
- **Ad blockers.** A meaningful share of visitors will block these scripts
  outright, PostHog included. Nothing here changes that; a first-party proxy
  would, later.
- **A CDN in the critical path of every page.** Already true of four
  dependencies. Pinning bounds the risk; integrity hashes would bound it
  further and are worth considering across all five at once rather than for
  this one.
- **Consent deferred while the tags ship.** Loading analytics before a consent
  mechanism exists is a deliberate ordering choice, and it is a real exposure
  for anyone with EU visitors. → It must be the next task, not an eventual one.

## Migration Plan

1. Build the addon and the application side in the base; new scaffolds get it.
2. Roll out to **one** project first, with a single provider, and confirm
   events actually arrive in that provider's dashboard — not that the script
   tag is present.
3. Add the second provider on the same project before touching the others, so
   plugin interactions surface once rather than five times.
4. Then the remaining projects, each needing a CMS rebuild for the addon and
   `gosite sync --app` plus an application rebuild for the templates.

Rollback is per project and cheap: disable the entries, or remove the addon.
Nothing else depends on it.

## Open Questions

Resolved during implementation:

- **Providers in the first release: GTM and PostHog.** Nothing else is guessed
  at; a third provider waits for a real request. What each needs is recorded in
  `src/knowledge/analytics-providers.md`, verified against the packages rather
  than against blog posts.
- **The environments field is a select over three values**, not a free list:
  `all`, `production`, `development`. It covers the case that matters — keeping
  development traffic out of a client's account — plus trying a new tool
  locally before it goes live, and it cannot be typed wrong. A free list of
  environment names would have to agree with whatever `APP_ENV` happens to hold
  across five projects, which is a coordination problem for no benefit.

Still open:

- Do the sites need subresource integrity on their CDN dependencies? Out of
  scope here, but this change adds the fifth one, which is a reasonable moment
  to ask.
