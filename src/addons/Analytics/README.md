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

## Adding a provider

Adding a *key* is data — an entry, no release.

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
