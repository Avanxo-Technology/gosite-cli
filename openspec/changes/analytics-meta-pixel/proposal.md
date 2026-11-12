## Why

Clients running Meta (Facebook) ads need the Meta Pixel on their site. Today the only way is to put it inside a GTM container, which hides it from the CMS and from the consent banner's per-provider view. Adding it as a provider lets a client paste the Pixel ID in the CMS, behind the same consent gate as every other tracker.

## What Changes

- New provider `meta-pixel` in the Analytics addon, with config `{ "pixelId": "..." }`.
- Consent category `marketing`. It never loads before the visitor accepts marketing cookies.
- A browser plugin written in the site (same pattern as PostHog): loads `fbevents.js`, calls `init` and sends `PageView` on every page view; `analytics.track()` from page code is forwarded to the Pixel.
- No `<noscript><img>` fallback, because it would fire without consent.
- Thin sites only (`core/`). The legacy browser file under `src/templates/` is frozen and does not get the plugin.

## Capabilities

### New Capabilities
- `analytics-meta-pixel`: the `meta-pixel` provider — CMS validation, consent category, browser plugin behaviour and what it never does.

### Modified Capabilities
<!-- None: Analytics has no spec in openspec/specs/ yet (add-analytics-integrations is not archived). -->

## Impact

- CMS addon: `src/addons/Analytics/Helper/Analytics.php` (`PROVIDERS`, `PROVIDER_CATEGORY`, `RULES`, `DOCS`, config template, the `custom` flag in `providerReference()`), `src/addons/Analytics/README.md`.
- Thin core: `core/internal/app/assets/js/analytics/analytics.js` (`CUSTOM`, `CUSTOM_CATEGORY`, new `metaPixelPlugin`).
- Tests: `tests/js/` for the plugin and the consent gate.
- Knowledge: `src/knowledge/analytics-providers.md`.
- Delivery: CMS rebuild (addon) and a core release (`core/vX.Y.Z` tag) for thin sites. `src/VERSION` bump.
