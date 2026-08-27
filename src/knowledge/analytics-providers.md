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

**No official plugin publishes a browser bundle.** Checked: `google-tag-manager`,
`google-analytics` and `simple-analytics` all 404 on their `dist/*.min.js`.
They ship CJS and ESM only, for bundlers. That is why every plugin here is ours.

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

**Stores:** a container id.

**Format:** `GTM-` followed by uppercase letters and digits, e.g. `GTM-ABC1234`.
Google has lengthened these over time, so validate the shape, not a length.

**Needs markup in two places** — this is a property of GTM, not something an
editor should have to know:

| where | what |
| --- | --- |
| `<head>` | create `dataLayer`, push `gtm.start`, inject `googletagmanager.com/gtm.js?id=<id>` |
| `<body>` | a `<noscript>` iframe to `googletagmanager.com/ns.html?id=<id>`, for visitors without JS |

**Events** go to `window.dataLayer.push({...})`. GTM itself decides what to do
with them, which is the whole point of it.

**Ready when** `window.dataLayer` exists — the container queues internally, so
pushes before the script arrives are not lost.

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
