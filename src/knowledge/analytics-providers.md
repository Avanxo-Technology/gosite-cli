# Analytics providers — what each one needs

What the `Analytics` addon stores per provider, and what the browser plugin has
to do with it. Adding a provider means adding a section here, a plugin, and an
option to the `provider` select — the three go together.

Verified on 2026-08-27 against the packages themselves, not against blog posts.
Re-check after a major version of either library.

Each provider also needs a **consent category**, without which it cannot load
at all. Those are in `analytics-consent-categories.md`, together with the
reasoning for the arguable ones.

## The library

`analytics` **v0.8.19** (2025-08-09). Loaded from a **pinned** CDN URL:

```
https://unpkg.com/analytics@0.8.19/dist/analytics.min.js
```

Pinned deliberately. An unpinned URL resolves to `latest`, which lets an
upstream release change five client sites with no deployment, prevents
subresource integrity, and costs a redirect. Every other dependency in
`layout.html` is pinned too.

### The core publishes `_analytics`, not `Analytics`

```js
var _analytics = { Analytics, CONSTANTS, EVENTS, default, init }
```

The factory is `_analytics.init`. Assuming a bare `window.Analytics` reports
the library as "did not load" while it is sitting there fully loaded — a
failure that reads as an ad blocker and sends you looking in the wrong place.

### Official plugins DO ship browser bundles — at a non-obvious path

This was got wrong once, so it is written down. The bundle is **not** at
`dist/analytics-plugin-<name>.min.js`; guessing that path returns 404 and looks
like proof the bundle does not exist. The real path repeats the scope:

```
https://unpkg.com/@analytics/<name>@<version>/dist/@analytics/<name>.min.js
```

Each is an IIFE assigning a global, so a plain `<script>` works. Verified by
evaluating each one and calling it:

| provider | pinned | global |
| --- | --- | --- |
| `gtm` | `google-tag-manager@0.6.0` | `analyticsGtagManager` |
| `google-analytics` | `google-analytics@1.1.0` | `analyticsGa` |
| `google-analytics-v3` | `google-analytics-v3@0.7.0` | `analyticsGa3` |
| `mixpanel` | `mixpanel@0.4.0` | `analyticsMixpanel` |
| `segment` | `segment@2.1.0` | `analyticsSegment` |
| `amplitude` | `amplitude@0.1.3` | `analyticsAmplitude` |
| `hubspot` | `hubspot@0.5.1` | `analyticsHubspot` |
| `fullstory` | `fullstory@0.2.7` | `analyticsFullStory` |
| `customerio` | `customerio@0.2.2` | `analyticsCustomerio` |

### Mounting must wait for `document.body`

The loader sits in `<head>` so the bundles start downloading early — but at
that point `document.body` is `null`, and the `google-analytics` plugin appends
its tag straight to `document.body`. Mounting there throws
`Cannot read properties of null (reading 'appendChild')` from inside the plugin
and nothing is ever sent.

Only the mount waits for `DOMContentLoaded`; the downloads still start
immediately, and the loader's queue holds any event raised meanwhile. The queue
is replayed only when the mounted batch was allowed when the page loaded. A
call made before a later accept on the same page is dropped, for every
provider: the visitor had not agreed to it yet.

### Two expose an ESM interop object, not the factory

`google-analytics` and `google-analytics-v3` set their global to
`{default: fn, ...}` rather than to the factory itself. The other seven set the
function directly. The loader unwraps `.default` when the global is not
callable, which is cheaper than keeping a list of which ones do it.

Symptom if this is missed: the bundle loads, the global exists, and the plugin
is never built — no request to the provider at all.

### Options the plugin iterates must be lists

`measurementIds` is plural because the GA4 plugin iterates it. Storing a lone
string there loads the plugin and sends nothing, with no error anywhere. The
addon wraps a scalar into a list on save for keys declared as lists, and the
config template offers `[""]` so the shape is visible before anything is typed.

### Four are published but unusable without a bundler

Do not add these back without re-checking. Each fails while evaluating the
bundle itself, before any DOM is involved:

| provider | why |
| --- | --- |
| `aws-pinpoint` | `_objectSpread is not defined` — the bundle references a helper it does not ship |
| `intercom` | `typeUtils is not defined` — same |
| `snowplow` | `require$$0 is not defined` — CommonJS leaked into the browser build |
| `simple-analytics` | no `dist/` at all; only `lib/` CJS and ESM |

### Only PostHog and Meta Pixel are ours

Meta Pixel has no maintained `@analytics` plugin either, so `metaPixelPlugin`
sits next to `posthogPlugin`.

`@analytics/posthog` does not exist, and the third-party ones
(`analytics-plugin-posthog` v0.0.3, `@metro-fs/...` v1.14.0) were both last
published in 2024 while `posthog-js` still ships releases. So it is the one
plugin written by hand, and it lives with the registry in
`static/js/analytics/analytics.js`.

### The plugin contract

A plugin is a plain object. Only `name` is required; everything else is
optional. No imports, so a plain `<script>` works.

```js
{
  name: 'provider-name',
  config: {},
  initialize: ({ config }) => {},
  page:       ({ payload }) => {},
  track:      ({ payload }) => {},
  identify:   ({ payload }) => {},
  loaded:     () => true,
}
```

**`loaded()` is the one that bites.** The library queues events until it
returns `true`. Return it too early and the first events — including the entry
page view — are handed to a provider that cannot accept them yet, and vanish
with no error. Return it never and nothing is ever sent. It is the only part of
a plugin worth verifying in a browser rather than by reading.

## Google Tag Manager

**Stores:** `containerId`.

**Format:** `GTM-` followed by uppercase letters and digits, e.g. `GTM-ABC1234`.
Google has lengthened these over time, so validate the shape, not a length.

**Stored as `containerId`**, which is what the official plugin's config calls
it — its full default config is `{debug, containerId, dataLayerName, dataLayer,
preview, auth, execution}`. Configuration is stored under the provider's own
key names and handed over untouched, so there is no translation layer to drift.

**The `<body>` half is ours**: a `<noscript>` iframe to
`googletagmanager.com/ns.html?id=<id>`, for visitors without JavaScript. A
script cannot supply that, which is why it is the one piece of per-provider
markup in the template.

## PostHog

**Stores:** a project API key and an API host.

`posthog-js` **v1.422.0** (2026-08-27) — actively maintained, unlike every
third-party `analytics` plugin for it (`@analytics/posthog` does not exist;
`analytics-plugin-posthog` is v0.0.3 from 2024-01-17). Hence our own plugin.

**Key format:** the documented prefix is `phc_`. Validate the character set and
a sensible length rather than hard-coding the prefix — a rejected valid key is
worse than an accepted odd one, and the escaping and the character rules below
already cover safety.

**Host:** configurable. `https://us.i.posthog.com` is the value in the shipped
type docs; PostHog also runs an EU region, and a first-party proxy path (e.g.
`/ph`) works too and survives ad blockers. Store it; never hard-code it.

**API**, from the shipped `module.d.ts`:

```
init(token, { api_host })
capture(event_name, properties?, options?)
identify(new_distinct_id?, userPropertiesToSet?, userPropertiesToSetOnce?)
reset()
```

**Ready when** `window.posthog.__loaded === true`. The instance carries that
flag; there is also a `loaded` callback in the init config. Use the flag for
the plugin's `loaded()`.

**Page views:** `capture('$pageview')`.

**Bundle size is opt-in.** `posthog-js` lazy-loads a separate chunk for session
recording, surveys and web experiments — together roughly 120KiB a visitor
downloads even on a site that uses none of them. All three are off by default
and re-enabled per project from the CMS config, which reaches the plugin
untouched:

| Config key        | Default | Effect when `true`                    |
| ----------------- | ------- | ------------------------------------- |
| `session_recording` | off   | records sessions (`disable_session_recording: false`) |
| `surveys`         | off     | loads and shows surveys               |
| `web_experiments` | off     | loads web experiments                 |
| `autocapture`     | **on**  | set to `false` to stop click/pageview autocapture |

`autocapture` is the one that defaults on: click and pageview data is what most
sites configure PostHog for, and it ships in the core bundle, so turning it off
saves nothing. The other three are inverted (`disable_x: config.x !== true`) so
an absent key means off, which is what an untouched CMS config produces.

## Meta Pixel

**Stores:** `pixelId`, 15 to 20 digits. **Needs:** `marketing`. **Thin sites
only** (the CMS checks `gosite.layout = thin` in `config.core.php`).

`initialize` installs Meta's `fbq` queue stub and then requests
`connect.facebook.net/en_US/fbevents.js`; calls made before the script runs
wait in `fbq.queue`, which the script drains. `loaded()` is true only once
`fbq.callMethod` exists, that is, once Meta's script has taken over. If a
blocker stops `fbevents.js`, it never becomes true and the library keeps the
Pixel's events queued; the other plugins of the same instance still receive
theirs (checked in Chrome with analytics@0.8.19 and a plugin whose `loaded()`
stays false).

Checked against Meta's reference (2026-11-13): 17 standard events go through
`fbq('track')` (`PageView` is sent separately by the plugin's `page`), other
names through `fbq('trackCustom')`, limited to 50 characters. The dedup id is
the fourth argument, `{eventID: ...}`; the plugin takes it from `order_id`. A
Conversions API copy must send the same value as `event_id`.

No `<noscript>` image: it would request `facebook.com/tr` before consent.

Withdrawing marketing reloads the page, and consent.js deletes `_fbp` and
`_fbc` at the next boot.

## Commerce events

The Commerce addon renders `ViewContent` (product page), `InitiateCheckout`
(checkout page) and `Purchase` (confirmation) as
`<script type="application/json" data-analytics-event>` blocks, and sends
`AddToCart` as the htmx trigger `analytics:event`. analytics.js reads them only
for providers allowed when the page loaded, and records sent `Purchase` order
ids in `sessionStorage` (`gosite_purchases`) so a reload does not count twice.

The product page is cached and shared, so its block holds store data only. The
confirmation page has no order read of its own: the Purchase payload is signed
into the `gosite_order` cookie when the cart completes, and `content_ids` is
dropped when it would push the cookie past about 4 KB. htmx adds `elt` to the
event detail, so a payload must not use the key `target`.

## Rules that apply to every provider

**Keys are public.** A GTM container id, a PostHog project key and a Meta Pixel
ID are served in
the HTML to every visitor. They are not secrets, which is why they can live in
the CMS and be edited by the client. Do not treat them as credentials, and do
not put anything that *is* a credential in this collection.

**Values reach the browser as data, never as code.** They are emitted in a JSON
block that the local script reads. Nothing from the CMS is interpolated into
JavaScript source, so a malformed value fails a `JSON.parse` instead of
executing.

`html/template` would in fact escape a value interpolated inside a `<script>` —
verified: `x");alert(1);//` renders as `x");alert(1);\/\/` — but only for
as long as nobody reaches for `safeHTML`. Delivering data as data removes the
question entirely.

**Validation happens at save time as well.** Quotes, angle brackets and
backslashes are refused in the addon, independently of any escaping later. Two
independent defences, neither relying on the other.
