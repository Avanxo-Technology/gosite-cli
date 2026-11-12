## Context

The Analytics addon stores one entry per provider; the site's `analytics.js` builds a plugin for each entry the visitor consented to. Official `@analytics/*` bundles are loaded from unpkg; PostHog is the one plugin written in the site (`CUSTOM = { posthog: posthogPlugin }`). An entry whose provider the browser file does not know is skipped with a console warning only (`analytics.js`, "no usable plugin").

Facts confirmed in Meta's documentation (developers.facebook.com/docs/meta-pixel/get-started and /reference, read 2026-11-12):
- the base code loads `https://connect.facebook.net/en_US/fbevents.js` and calls `fbq('init', id)` and `fbq('track', 'PageView')`;
- 17 standard events: AddPaymentInfo, AddToCart, AddToWishlist, CompleteRegistration, Contact, CustomizeProduct, Donate, FindLocation, InitiateCheckout, Lead, Purchase, Schedule, Search, StartTrial, SubmitApplication, Subscribe, ViewContent;
- the base code includes a `<noscript><img src="https://www.facebook.com/tr?...">` fallback;
- the Pixel ID format is **not** documented.

## Goals / Non-Goals

**Goals:**
- A client can enable the Pixel from the CMS without a code change.
- Same consent guarantees as every other provider.

**Non-Goals:**
- Conversions API (server-side events). It needs a secret access token, which must never be in this public collection; it is a separate mechanism.
- Wiring Forms or Commerce to send `Lead`/`Purchase` automatically. Page code can call `analytics.track()`; automatic events are a later change.
- Legacy sites. `src/templates/` is frozen.
- Advanced matching (hashed e-mail/phone). It sends personal data and needs its own consent review.

## Decisions

### D1. Own plugin, not a third-party bundle and not GTM
Chosen by the user (option A). Same reasons as PostHog: no maintained `@analytics` plugin is known to us, and keeping it in the CMS keeps consent per provider. The plugin follows `posthogPlugin`: `initialize` injects the standard `fbq` queue stub and the script, `page` sends `PageView`, `track` forwards events, `loaded` reports ready only once `fbevents.js` has run.

The `fbq` queue stub matters: it makes calls made before the script loads queue instead of failing, which covers "event before the script loaded".

### D2. `pixelId` is required: digits only, 15 to 20
Meta's developer pages do not state the format. Third-party setup guides agree that the ID is numeric only (no letters, dashes or prefixes); most say 15 or 16 digits, one allows up to 20. The pattern `/^[0-9]{15,20}$/` catches the usual mistakes — the ad account id (`act_…`) or the whole base code pasted in — and the upper bound follows the widest source, because a rejected valid key is worse than an accepted odd one. If a valid ID is ever rejected, widen the range; the character rules in `sanitize()` still apply.

### D3. `track` vs `trackCustom` by name
Standard event names go to `fbq('track')`, everything else to `fbq('trackCustom')`. The 17 names come from Meta's reference page. `trackCustom` is not on the pages read; its behaviour comes from training data and is verified in task 3.2 before release.

### D4. No noscript fallback
The image request in the base code fires without JavaScript, so the consent gate cannot block it. Without it, visitors without JavaScript are not tracked — the correct outcome.

### D5. Category `marketing`, declared explicitly
Unknown providers already fall to `marketing`, but `CUSTOM_CATEGORY['meta-pixel'] = 'marketing'` and `PROVIDER_CATEGORY` make it explicit, so a later change to the fallback cannot change this provider.

### D6. The `custom` flag in `providerReference()` becomes a list
Today it is `$value === 'posthog'`. It becomes a `CUSTOM_PROVIDERS` constant so the admin reference table shows both own plugins correctly.

## Risks / Trade-offs

- [A legacy site's CMS offers Meta Pixel, but its browser file has no plugin, so the entry saves and never loads] → the README and the admin screen help text say the provider needs an up-to-date site; listed in Open Questions.
- [Meta changes the script or the `fbq` API] → the plugin is small and in one place; the JS tests pin the calls it makes.
- [Ad blockers block `connect.facebook.net`] → expected; out of scope (no first-party proxy).
- [A Pixel ID with a wrong digit saves without error] → the pattern checks the shape only; the admin screen shows the stored ID.

## Migration Plan

1. Release gosite with the addon change and the core change; tag `vX.Y.Z` and `core/vX.Y.Z` on the same commit after green CI.
2. Per thin site: `go get` the new core, rebuild the CMS image and the app.
3. Rollback: disable the entry in the CMS; no data migration.

## Open Questions

- Legacy sites: hide `meta-pixel` from the select on legacy sites, or accept the risk above?
- Automatic `Lead` from Forms and `Purchase` from Commerce: a follow-up change?
