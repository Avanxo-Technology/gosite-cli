## Context

`analytics.js` reads a JSON block, fetches the bundles its configured providers
need, mounts the `analytics` core with one plugin each, and calls `page()`. Its
header comment already reserves itself as the single mount point where consent
hooks. This change takes that hook.

The constraint that shapes everything else is the cache. Pages are cached in
Redis per project and purged site-wide when anything in the layout changes. A
visitor's consent decision must therefore be invisible to the server.

**Non-Goals:**

- Google Consent Mode v2. Noted as pending, by decision.
- A server-side record of consent. Noted as pending, by decision, with the copy
  version stored now so the record remains possible.
- Consumers other than analytics.

## Decisions

### Our own banner, not a library

vanilla-cookieconsent and Klaro are both mature, MIT and dependency-free. The
argument against them is not size, it is the source of truth: each brings its
own configuration schema describing categories and services, which would sit
next to the CMS collection already describing exactly that. The analytics work
chose plugins over snippets to get one uniform contract; two competing
descriptions of the same providers is the opposite of that.

The real surface here is small: a cookie, three categories, a gate, a banner
and a dialog. What we take on instead is the banner's own quality — keyboard
handling, focus trapping in the dialog, contrast — which a library would have
given us. That is a genuine cost, accepted knowingly, and it is why the tasks
call out accessibility explicitly rather than leaving it implied.

### A separate file, not more of `analytics.js`

`analytics.js` is deliberately one file holding three things. Adding a banner,
a dialog and a cookie would make it four, and the fourth is the only one with
its own UI.

Separating them also means the gate can serve consumers that are not analytics.
An embedded map or a video player is the same problem, and `window.consent` is
the shape that answers it. Nothing else is wired here, but the seam is where it
would go.

### The cookie, not localStorage

A first-party cookie survives subdomains and is readable by the server if a
future need arises. `localStorage` is neither.

Its value is a small JSON object: a schema version, the copy version shown, a
timestamp, and the granted categories. It is not `HttpOnly`, because the
browser has to read it; it carries `SameSite=Lax` and a documented lifetime.

Two versions, on purpose. The schema version re-asks when the set of
categories changes, which is a substantive change to what is being consented
to. The copy version does not re-ask — otherwise every typo fix would re-prompt
every visitor — but it is recorded, so a later server-side record can say which
text a given decision was made against.

### Blocking, not deferring the mount

The bootstrap's `Promise.all` over `loadScript` moves behind the gate, not just
`mount()`. Fetching `unpkg.com/@analytics/...` is already a request to a third
party with a referrer, and PostHog's plugin fetches from the client's own
PostHog host. Waiting only to mount would mean the visit is disclosed before
anyone agreed to anything.

The core bundle in `analytics.html` is a different case: it is a CDN request
that discloses the visit but sets nothing and identifies nobody. It stays in the
head unconditionally, so the gap between accepting and tracking is short. This
is a defensible line rather than an obvious one, and it is written down here so
it can be revisited as one decision instead of drifting.

### Withdrawal reloads the page

`analytics@0.8.19` has `plugins.disable()` but no clean unmount, and the
provider bundles have already run their own initialisation by then — PostHog has
a live instance with its own persistence. Pretending to detach it would give a
false sense of what actually stopped.

So withdrawal clears the cookie, clears the providers' own storage where the
provider documents a way to, and reloads. The reload is honest: what comes back
is a page that never loaded the tracker. The cost is a visible reload on a rare
action.

### Category defaults live next to the plugin, overridable from the CMS

The registry in `analytics.js` already holds each provider's bundle path and
global. Its category belongs there too, because it is a property of the
provider, and because that keeps `OFFICIAL` the one place a provider is
described.

GTM is why the CMS can override it. A container can hold nothing but a GA4 tag,
or it can hold an advertising pixel, and only the person who built the container
knows. Default it to marketing, the safer reading, and let the site owner lower
it.

## Risks / Trade-offs

- **Our banner's accessibility is now our problem.** → Focus trap, escape,
  labelled controls and contrast are explicit tasks, verified in a browser
  rather than assumed.
- **The core bundle loads before consent.** → A deliberate line, argued above.
  Revisit as one decision if a client's counsel disagrees.
- **No proof of consent.** → Accepted and written down; the copy version ships
  now so the record can be added without a gap in the history.
- **A cached page carries the banner for a visitor who already decided.** → The
  banner is hidden client-side from the cookie, read synchronously before
  paint. A flash of the banner for a returning visitor is the failure mode to
  watch for in verification.
- **Analytics rollout is mid-flight.** The addon is on `analytics-draft` and
  pending on the client projects. → Ship consent before the remaining rollout,
  so no project ever gets tracking without a banner.

## Migration Plan

1. Build the addon half and the client half in the base; new scaffolds get it.
2. Verify on `analytics-draft`: no third-party request before a decision, per
   category gating after one, withdrawal actually stops it.
3. Roll out to the one project already carrying analytics, CMS rebuild plus
   `gosite sync --app`, before that project's rollout goes any further.
4. Then the projects still pending analytics get both at once.

Rollback is per project: disabling the consent singleton returns the site to
0.46.0 behaviour, which is tags loading unconditionally. That is a legal
regression, not a neutral one, so it is a switch for debugging rather than an
operational option.
