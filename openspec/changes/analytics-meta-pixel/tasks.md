## 1. CMS addon

- [ ] 1.1 Add `meta-pixel` to `PROVIDERS`, `PROVIDER_CATEGORY` (`marketing`), `RULES` (`pixelId` required) and `DOCS` (Meta Pixel get-started page) in `src/addons/Analytics/Helper/Analytics.php`
- [ ] 1.2 Replace the `=== 'posthog'` check in `providerReference()` with a `CUSTOM_PROVIDERS` constant
- [ ] 1.3 Add Meta Pixel to the config `info` text; check the config template shows `pixelId`

## 2. Browser plugin (core)

- [ ] 2.1 Add `metaPixelPlugin` to `core/internal/app/assets/js/analytics/analytics.js` with the `fbq` queue stub, `initialize`, `page`, `track` (standard vs custom) and `loaded`
- [ ] 2.2 Register it in `CUSTOM` and `CUSTOM_CATEGORY`
- [ ] 2.3 Confirm the analytics partial renders no noscript fallback for `meta-pixel`

## 3. Tests

- [ ] 3.1 Add JS tests in `tests/js/`: no script before marketing consent, init + PageView after consent, `track` vs `trackCustom`, queued event before load, withdraw clears `_fbp`/`_fbc`
- [ ] 3.2 Verify `trackCustom` against Meta's documentation (advanced/custom events page) before release
- [ ] 3.3 Add a Go view test that the rendered HTML has no `facebook.com/tr` request

## 4. Sandbox verification

- [ ] 4.1 In `~/gosites/analytics-draft-v2`, add a `meta-pixel` entry with a test Pixel ID; check with the browser that nothing loads before consent and that `fbevents.js` and PageView fire after consent
- [ ] 4.2 Capture the network panel before and after consent for the PR

## 5. Docs and release

- [ ] 5.1 Update `src/addons/Analytics/README.md` (supported providers, category table) and `src/knowledge/analytics-providers.md`
- [ ] 5.2 Bump `src/VERSION`; CHANGELOG entry: CMS rebuild + core update for thin sites
