# Cookie consent — the categories, the cookie, and why each is what it is

The decisions behind the consent half of the `Analytics` addon. Written down
because most of them are judgements rather than facts, and a judgement nobody
recorded gets re-litigated or, worse, quietly reversed.

Decided 2026-09-10, shipped in 0.53.0.

## Three categories

`necessary`, `analytics`, `marketing`.

More categories look more precise and are worse. Every extra switch is another
thing a visitor has to understand before they can leave the banner, and none of
the providers this addon supports need a finer split. A fourth category should
have to justify itself against that.

`necessary` is never refusable and **nothing in this addon belongs to it**. A
tracking tool is by definition not necessary for a page to work, and a category
nobody can refuse would otherwise become a way to load tracking without
consent. It is shown in the dialog anyway, as always-on: the visitor should see
the full list of what runs, including the part they cannot turn off.

## Which provider needs which

| provider | category | why |
| --- | --- | --- |
| `gtm` | `marketing` | see below |
| `hubspot` | `marketing` | a CRM whose purpose is contacting the person |
| `customerio` | `marketing` | messaging and campaigns |
| `posthog` | `analytics` | product analytics |
| `google-analytics`, `google-analytics-v3` | `analytics` | measurement |
| `mixpanel`, `segment`, `amplitude` | `analytics` | measurement |
| `fullstory` | `analytics` | session analysis |

**GTM is the one that is arguable.** A container can hold nothing but a GA4 tag,
or it can hold an advertising pixel, and the site owner is the only person who
knows which. Defaulting it to `marketing` asks for more consent than a
measurement-only container needs; defaulting it to `analytics` would load
advertising tags for a visitor who refused advertising. The second failure is
the one that matters, so the default is `marketing` and the CMS can lower it per
entry.

`fullstory` is the second arguable one: session replay records what a person
did on the page, which several authorities treat as closer to profiling than to
counting. It is `analytics` here because that is what it is sold as, but a
client with EU visitors and a strict reading may want it moved.

**Two copies of this mapping, on purpose.** `PROVIDER_CATEGORY` in
`Helper/Analytics.php` is what the admin screen shows; `OFFICIAL[...].category`
and `CUSTOM_CATEGORY` in `static/js/analytics/analytics.js` are what actually
gates. Same reason `PROVIDERS` is already duplicated: the browser cannot read
PHP and neither may become the other's source of truth at page render time,
because consent must never touch the server. An unknown category resolves to
`marketing` on the browser side — the hardest consent to obtain — so a typo
costs tracking, never permission.

## The copy arrives seeded, in Spanish, and off

The singleton is created with real Spanish wording rather than empty fields.
The reason is narrow: the application carries last-resort text so a legal
notice never renders a blank button, and that text is all an empty singleton
has — so an editor who simply ticked the box published an English banner on a
Spanish site.

The Go fallbacks in `internal/analytics/consent.go` are Spanish for the same
reason, and the two must stay in step. An English fallback beside seeded
Spanish means deleting one field produces a banner in two languages. A site in
another language overwrites the copy in the CMS, which is where that decision
belongs. `TestFallbacksMatchTheSeededLanguage` fails if one side drifts.

Two fields are deliberately **not** seeded:

- `enabled`, because publishing a legal notice is the site owner's decision.
  Enabling an integration does not enable the banner either; the two are
  independent, and integrations-on with consent-off loads nothing.
- `policyUrl`, because there is no value we could invent and a wrong
  privacy-policy link is worse than a missing one. Empty means no link shown.

Seeding runs once, from the branch that creates the model, so an upgrade never
overwrites copy a client reviewed. It writes `_state: 1` explicitly — a seeded
draft would be invisible to the read API and the banner would fall back to the
very text the seeding exists to avoid, while looking filled in to whoever
opened the editor.

## The cookie

`gosite_consent`, first-party, `Path=/`, `SameSite=Lax`, `Secure` over HTTPS,
182 days.

A cookie rather than `localStorage`: it survives subdomains, and it is readable
by the server if a server-side record of consent is ever built. `localStorage`
is neither and would have to be migrated the day that is wanted.

182 days is the short end of what supervisory authorities have called
reasonable. A year is common and defensible. Much longer starts to look like
avoiding the question.

The value is JSON:

```json
{"schema":1,"copyVersion":"2026-09","decidedAt":"…","granted":{"analytics":true,"marketing":false}}
```

**Two versions, and they do different things.**

- `schema` versions the *category list*. Bumping it invalidates every stored
  decision and re-asks, so it moves only when what is being consented **to**
  changes — a category added, removed or redefined.
- `copyVersion` versions the *wording*, comes from the CMS, and is never
  compared. Re-prompting every visitor over a typo teaches people to click
  whatever dismisses the banner fastest.

Anything not exactly right — malformed, hand-edited, a different schema — is
treated as **no decision at all**, never as a partial one. Reading half a
decision would mean granting something the visitor may never have agreed to.

## Why `copyVersion` exists at all when nothing reads it

Because the alternative is losing history that cannot be reconstructed.

The record of consent today is a cookie in the visitor's own browser, which
they can edit or clear, and which we have no copy of. That is not proof anybody
agreed to anything. A server-side record — an endpoint, a collection, a
retention policy — is separate work and deliberately not in 0.53.0.

Storing the version now is the cheap half. Without it, a decision made against
wording an editor has since changed can never be tied to what the visitor
actually read, and no later feature can recover that.

## Two lines that are easy to get wrong

**The gate covers the downloads, not just the mount.** Fetching a bundle from
unpkg is already a request to a third party carrying this site's referrer, and
PostHog's plugin fetches from the client's own host. Deferring only `mount()`
would disclose the visit before anyone agreed.

**The `analytics` core is the exception.** It stays in the layout head,
unconditionally, because it is a CDN request that sets nothing and identifies
nobody, and having it parsed keeps the gap between accepting and tracking short.
This is a defensible line rather than an obvious one. If a client's counsel
disagrees, move it behind the gate — it is one `<script>` in
`components/analytics.html` — and accept the delay.

## Withdrawal reloads

`analytics@0.8.19` has `plugins.disable()` and no clean unmount, and by the time
a category is withdrawn the provider has run its own initialisation: PostHog has
a live instance with its own persistence. Calling a disable and reporting
success would claim something stopped when it can still send.

So withdrawal clears the cookie, best-effort clears the known vendors' cookies
and storage keys, and reloads. What comes back is a page that never loaded the
tracker, which is the only honest version of "it stopped".

Granting a *second* category does **not** reload. The library fixes its plugin
list at construction, so each grant mounts its own instance and `window.analytics`
fans out to all of them.

## Not shipped, by decision

- **Google Consent Mode v2.** The opposite shape: load with denied defaults,
  then update. A client running Google Ads in the EEA will want it, as a mode
  per provider.
- **A server-side record of consent.** See above.
- **PostHog's own consent API** (`opt_out_capturing_by_default`, memory
  persistence), which would allow cookieless measurement before a decision
  instead of blocking outright. More work and harder to explain to a client.
