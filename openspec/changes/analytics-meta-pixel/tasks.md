## 1. CMS addon

- [ ] 1.1 Add `meta-pixel` to `PROVIDERS`, `PROVIDER_CATEGORY` (`marketing`), `RULES` (`pixelId` required, `/^[0-9]{15,20}$/`) and `DOCS` (Meta Pixel get-started page) in `src/addons/Analytics/Helper/Analytics.php`
- [ ] 1.2 Replace the `=== 'posthog'` check in `providerReference()` with a `CUSTOM_PROVIDERS` constant
- [ ] 1.3 Add `THIN_ONLY_PROVIDERS = ['meta-pixel']`; drop them from the select and refuse them on save unless `$app->retrieve('gosite/layout') === 'thin'`
- [ ] 1.4 Add Meta Pixel to the config `info` text; check the config template shows `pixelId`

## 2. Scaffold

- [ ] 2.1 Add `'gosite' => ['layout' => 'thin']` to `src/templates-thin/generated/cockpit/config.core.php`
- [ ] 2.2 Check `gosite generate` on a sandbox copy rewrites it (thin) and that legacy templates are untouched

## 3. Browser plugin (core)

- [ ] 3.1 Add `metaPixelPlugin` to `core/internal/app/assets/js/analytics/analytics.js` with the `fbq` queue stub, `initialize`, `page`, `track` (17 standard names → `track`, others → `trackCustom`, `order_id` → `eventID`) and `loaded`
- [ ] 3.2 Register it in `CUSTOM` and `CUSTOM_CATEGORY`
- [ ] 3.3 Read `script[type="application/json"][data-analytics-event]` blocks and `HX-Trigger` `analytics:event` after consent, and call `analytics.track()`; keep sent `Purchase` order ids in `sessionStorage`
- [ ] 3.4 Confirm the analytics partial renders no noscript fallback for `meta-pixel`

## 4. Commerce events (core)

- [ ] 4.1 PDP: render a `ViewContent` data block (variant id, price, currency)
- [ ] 4.2 Add to cart: set `HX-Trigger` with `AddToCart` on the htmx response; no event on the no-JavaScript redirect path
- [ ] 4.3 Checkout: render an `InitiateCheckout` data block (cart total, currency, variant ids, item count)
- [ ] 4.4 Confirmation: read the order total and lines (reuse the order already read for the cookie check if there is one) and render a `Purchase` data block
- [ ] 4.5 Go tests for each data block and header, including a product title with `"` and `</script>`

## 5. Tests (JS)

- [ ] 5.1 `tests/js/`: no script before marketing consent, init + PageView after consent, `track` vs `trackCustom`, queued event before load, withdraw clears `_fbp`/`_fbc`
- [ ] 5.2 `tests/js/`: data blocks and `HX-Trigger` reach `analytics.track()` only after consent; no replay after a later accept; `Purchase` once per order id
- [ ] 5.3 Verify `trackCustom` and `eventID` against Meta's documentation before release
- [ ] 5.4 Go view test that the rendered HTML has no `facebook.com/tr` request

## 6. Sandbox verification

- [ ] 6.1 In `~/gosites/analytics-draft-v2`, add a `meta-pixel` entry with a test Pixel ID; check in the browser that nothing loads before consent and that `fbevents.js` and PageView fire after consent
- [ ] 6.2 With the Commerce addon in a sandbox site, walk product → cart → checkout → confirmation and capture the four events in the network panel
- [ ] 6.3 Confirm a legacy sandbox CMS does not offer Meta Pixel

## 7. Docs and release

- [ ] 7.1 Update `src/addons/Analytics/README.md` (supported providers, category table, Commerce events) and `src/knowledge/analytics-providers.md`
- [ ] 7.2 Bump `src/VERSION`; CHANGELOG entry: `gosite generate`, CMS rebuild and core update for thin sites
