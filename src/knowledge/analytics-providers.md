# Analytics providers — what each one needs

What the `Analytics` addon stores per provider, and what the browser plugin has
to do with it. Adding a provider means adding a section here, a plugin, and an
option to the `provider` select — the three go together.

Verified on 2026-08-27 against the packages themselves, not against blog posts.
Re-check after a major version of either library.

## The library

`analytics` **v0.8.19** (2025-08-09). Loaded from a **pinned** CDN URL:

```
https://unpkg.com/analytics@0.8.19/dist/analytics.min.js
```

Pinned deliberately. An unpinned URL resolves to `latest`, which lets an
upstream release change five client sites with no deployment, prevents
subresource integrity, and costs a redirect. Every other dependency in
`layout.html` is pinned too.

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

### Only PostHog is ours

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

## Rules that apply to every provider

**Keys are public.** A GTM container id and a PostHog project key are served in
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
