# Analytics

Third-party tracking integrations for gosite sites — Google Tag Manager,
PostHog, and whatever comes next.

One collection holds one entry per integration. The application reads it
through Cockpit's core REST API and loads the matching browser plugin. This
addon serves nothing to visitors.

## These keys are public

A GTM container id and a PostHog project key are in the HTML of every page,
where anyone can read them. That is precisely what makes it safe to keep them
in the CMS and let a client edit them.

> **Never put a real credential in this collection.** A PostHog *personal* API
> key, a server-side token, anything that grants write access — none of it
> belongs here. If it must not be public, it is not configuration for a
> browser.

## The model

`analyticsIntegrations`, grouped under **Analytics** in the Content sidebar.

| field | what |
| --- | --- |
| `provider` | a select, limited to providers the site has a plugin for |
| `config` | an object; its shape depends on the provider |
| `enabled` | turn a provider off without losing its configuration |
| `category` | which consent this needs; empty means the provider's default |
| `environments` | `all`, `production` or `development` |

### Supported providers

```json
gtm      { "id": "GTM-ABC1234" }
posthog  { "key": "phc_...", "host": "https://us.i.posthog.com" }
```

`environments` exists so development traffic does not land in a client's
production account. An entry set to `production` is invisible to a site running
with `APP_ENV=development`, and the reverse. Both halves have to line up for an
integration to be live: **enabled** *and* **covering this environment**. One
without the other is the usual reason somebody reports missing data, so the
admin screen says which entries are actually live here.

## Cookie consent

**Nothing here loads until a visitor agrees to it.** That is the single most
important thing to know about this addon, and it is easy to mistake for a
fault: a healthy list of integrations tracks nobody while the banner is off.

The banner is the `analyticsConsent` singleton, in the same **Analytics** group.

It arrives **filled in, in Spanish, and switched off**. Ticking *Ask for
consent* is enough to publish a usable banner; edit the wording first if the
site's voice differs. Two things the seeding deliberately leaves alone:
`enabled`, because publishing a legal notice is the site owner's decision and
not ours, and `policyUrl`, because there is no value we could invent and a
wrong privacy-policy link is worse than a missing one. With that field empty no
link is shown.

Enabling an integration does **not** enable the banner. The two are
independent, and the pairing a new project starts with — integrations on,
consent off — loads nothing. That is the safe direction: the alternative would
publish a legal notice nobody had read.

The seeding runs once, when the model is created. An upgrade never overwrites
copy a client has reviewed.

| field | what |
| --- | --- |
| `enabled` | ask for consent. **Off means no banner *and* no tracking.** |
| `copyVersion` | an identifier for the wording, stored with each visitor's choice |
| the banner group | title, text, the four button labels, the policy link |
| the categories group | a label and a description for each of the three |

### The three categories

`necessary`, `analytics`, `marketing`. Necessary is shown as always on and is
never refusable, and nothing in this addon belongs to it — a tracking tool is
by definition not necessary for a page to work.

Each provider has a default:

| provider | needs |
| --- | --- |
| Google Tag Manager | `marketing` |
| HubSpot, Customer.io | `marketing` |
| PostHog, GA4, Universal Analytics, Mixpanel, Segment, Amplitude, FullStory | `analytics` |

**GTM defaults to marketing, and that is a judgement rather than a fact.** A
container can hold nothing but a GA4 tag, or it can hold an advertising pixel,
and only whoever built the container knows which. Marketing is the safer
reading. If yours is analytics only, set the entry's `category` to `analytics`
and the banner will ask for less.

### What `copyVersion` is for

It records *which wording* a visitor agreed to, inside their cookie. Changing
it does **not** re-ask anybody, so bump it when the meaning of the text
changes, not for a typo.

It exists because the record of consent this addon keeps today is a cookie in
the visitor's own browser, which they can edit or clear — and that is not proof
that anybody agreed to anything. A server-side record is a separate piece of
work. Storing the version now is the half that cannot be reconstructed later:
without it, a decision made against text you have since changed cannot be tied
to what the visitor actually read.

### Letting a visitor change their mind

Withdrawing has to be as easy as consenting. Put `data-consent-open` on any
element and it reopens the preferences:

```html
<a href="#" data-consent-open>Cookie settings</a>
```

The layout renders one automatically. Move it into the site's own footer and
drop the `consent-link` block if that reads better.

Withdrawing a category **reloads the page**. The `analytics` library has no
clean unmount and a provider has already run its own initialisation by then, so
telling you it stopped without reloading would be a claim we cannot back.

### What is not here, on purpose

- **Google Consent Mode v2.** This addon blocks outright: nothing is fetched
  before a decision. Consent Mode is the opposite shape — load with denied
  defaults, then update — and a client running Google Ads in the EEA will want
  it. It is a mode to add per provider, not a reason to complicate the default.
- **A server-side record of consent.** See `copyVersion` above.

## Adding a provider

Adding a *key* is data — an entry, no release.

A new provider needs a category as well as a plugin: an entry in
`PROVIDER_CATEGORY` here and in `CUSTOM_CATEGORY` or the `OFFICIAL` registry in
`static/js/analytics/analytics.js`. The browser copy is the one that gates; the
PHP copy is what the admin screen shows. A provider with no category anywhere
resolves to `marketing`, which is the hardest consent to obtain — an unknown
must never be easier to load than a known one.

Adding a *kind of tool* is not, and deliberately so. Something has to know how
to render it, so three things move together:

1. a plugin in the application, under `static/js/analytics/`
2. an entry in `PROVIDERS` in `Helper/Analytics.php`, which is what the select
   offers
3. a branch in the `analytics` template component

If they drift, the failure is loud rather than silent: a provider that is not
in the select cannot be saved at all, instead of saving and never appearing.

## Validation

Configuration is checked when it is saved, not when it is rendered:

- the provider must be one the site can render
- required keys must be present, and text
- keys with a well-documented shape are matched against it — a GTM id must look
  like `GTM-ABC1234`
- quotes, angle brackets and backslashes are refused in every value, for every
  provider
- keys the provider does not declare are dropped rather than stored, so nobody
  believes an extra field does something

That is one of **two independent defences**. The other is that the application
never interpolates these values into JavaScript: they travel to the browser in
a JSON block that a local script reads, so a bad value fails a `JSON.parse`
instead of executing. Either would do on its own; together, a mistake in one is
not a vulnerability.

## Admin screen

`GET /analytics`, gated on `analytics/manage` (Settings > Roles). It lists every
integration with its provider, its state, its configuration and where it
applies — and flags the ones that are not live in this environment.

Editing happens in the normal Content editor, which already knows how to render
a select, an object and a boolean. The screen exists for the one thing Content
cannot show: whether an integration is actually running.

## What is not here

- **Consent.** No cookie banner, no consent mode, no deferred loading. A
  separate task — and one worth doing, because tags load unconditionally today.
- **Server-side events.** PostHog has a backend SDK, which is more reliable than
  anything in a browser. Different mechanism, different data path.
- **A first-party proxy** to survive ad blockers. Worth doing later; this stack
  already proxies `/storage/uploads`, so the pattern exists.

## Installing

The addon is baked into the CMS image, so an existing project needs a **CMS
rebuild**, not a restart. The browser plugins are application code, so they need
the application files brought up to date by hand (see MIGRATIONS.md in the
gosite repo) and an application rebuild.

See `src/knowledge/analytics-providers.md` for what each provider needs and why.
