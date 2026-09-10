## Why

The `Analytics` addon shipped in 0.46.0 and loads third-party tracking
unconditionally. Its own design named this: consent was deferred deliberately,
on the condition that it be the next task and not an eventual one. It is a real
exposure for any client site with EU visitors, and the exposure grows with
every project the addon rolls out to.

The mechanism belongs in the same addon, not a new one. The thing being gated
is the integrations that addon stores, the categories are a property of those
providers, and a separate addon would let a project install tracking without a
banner.

## What Changes

- **A consent singleton in the `Analytics` addon.** Enabled, the banner copy,
  the link to the privacy policy, and a copy version. The copy is content, so
  changing it is not a release. Saving it purges the project's cache, through
  the site-wide invalidation the analytics work already added.
- **A category per provider.** Three categories and no more: necessary,
  analytics, marketing. Each provider declares a default in the client-side
  registry it already has an entry in; the CMS can override it per entry,
  because GTM can fire either kind of tag and only the site owner knows which.
- **A new `consent.js`, distributed with `analytics.js`.** It owns the cookie,
  the banner, the preferences dialog and nothing else. It publishes
  `window.consent` with `get`, `onChange`, `open` and `reset`.
- **`analytics.js` becomes a subscriber.** Today its bootstrap fetches every
  needed bundle and then mounts. Both move behind consent: fetching a bundle
  from a CDN already contacts a third party, so waiting only to mount would
  leak the visit.
- **A documented way to withdraw.** A selector any footer can carry to reopen
  the preferences. Withdrawing has to be as easy as consenting.
- **The decision is client-side only.** No handler reads the consent cookie and
  no rendered page varies by it. Pages are cached in Redis per project, so a
  server-rendered banner state would fix the first visitor's choice for
  everyone else until the cache expired.

Explicitly out of scope, deliberately:

- **Google Consent Mode v2.** Blocking outright is correct and simple. Consent
  Mode is the opposite shape — load with denied defaults, then update — and a
  client running Google Ads in the EEA will eventually want it. It is a per
  provider mode to add later, not a reason to complicate the first version.
- **A server-side record of consent.** Proving months later that a given
  visitor consented, to what, and against which text, needs an endpoint, a
  collection and a retention policy. A cookie the visitor can edit is not
  proof. What ships here is the one cheap half that makes the record possible
  later: the copy version is stored inside the cookie from the first day, so
  the history can be reconstructed rather than lost.
- **Gating anything other than analytics.** Embedded maps and video players are
  the obvious next consumers, and `window.consent` is deliberately general
  enough for them, but nothing else is wired here.

## Capabilities

### New Capabilities

- `consent-storage-and-ui`: the cookie and its shape, the three categories, the
  versioning that decides when to ask again, the banner and the preferences
  dialog, reopening them, and the public browser API.
- `consent-gated-analytics`: what the analytics loader may and may not do
  before a decision exists, per-category gating, what happens on withdrawal,
  and the guarantee that no cached page varies by consent.

### Modified Capabilities

`analytics-page-integration` and `analytics-key-storage` both change, but
`openspec/specs/` is still empty and neither has been archived into it, so the
deltas live in the two new capabilities above rather than as MODIFIED blocks
against specs that are not there yet.

## Impact

**New source:**
- `src/templates/static/js/analytics/consent.js`
- `src/templates/static/css/consent.css` — no inline styles, so a CSP stays
  possible
- a `consent.html` component in both template flavors

**Modified source:**
- `src/addons/Analytics/bootstrap.php` — the singleton, its fields, the
  category field on the integration model, the purge hook
- `src/addons/Analytics/README.md`
- `src/templates/static/js/analytics/analytics.js` — the bootstrap waits
- `src/templates/flavors/*/internal/views/components/analytics.html` — load
  `consent.js` first
- `src/templates/flavors/*/internal/views/layout.html` — the consent blocks
- `src/templates/internal/views/render.go` — a template function for the
  consent settings, alongside `analyticsIntegrations`

**External contracts this rests on:**
- `analytics@0.8.19` has no clean unmount. Withdrawal therefore cannot silently
  detach a mounted plugin; see the design.

**Distribution:** the addon is baked into the CMS image, so existing projects
need a CMS rebuild. The scripts and templates need `gosite sync --app` and an
application rebuild. Same two-rebuild story as 0.46.0.

**Version:** user-facing, so `src/VERSION` bumps and `docs/index.html` and
`README.md` need updating.
