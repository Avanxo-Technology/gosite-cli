## 1. Addon contract

- [x] 1.1 Add `Configure func(siteconfig.Config) error` to `addon.Addon`; call it from `gosite.New` before `Mount`; startup fails on its error
- [x] 1.2 Tests: valid keys, rejected value, addon without `Configure` (Blog) unchanged

## 2. Commerce package skeleton

- [x] 2.1 `core/internal/addons/commerce` with self-registration, blank import in `core/gosite.go`
- [x] 2.2 `Configure`: `commerce_region`, `commerce_plp_path`, `commerce_pdp_path`, `commerce_checkout_path`, `COMMERCE_URL` (default `http://medusa:9000`); defaults and collision checks
- [x] 2.3 `currentRegion(c)` as the only region source
- [x] 2.4 Publishable key loader with retry; store routes answer 503 until loaded

## 3. Store API client

- [x] 3.1 Typed client: regions, products (list/by handle, category filter, pagination), categories, carts, line items, shipping options, payment providers, payment collections/sessions, complete
- [x] 3.2 Tests against an `httptest` fake of the Store API, including `type: \"cart\"` on complete

## 4. PLP and PDP

- [x] 4.1 PLP handler and page with category filter and pagination, cached under `page:commerce:<region>:`
- [x] 4.2 PDP handler and page, 404 for unknown or unpublished handles
- [x] 4.3 `/_commerce/buy/:handle` island (price, stock, add form); Alpine variant selector reloads it

## 5. Cart

- [x] 5.1 Cookie codec and stale-cookie handling (missing, completed, other region)
- [x] 5.2 Lazy create on first add; add, update quantity, remove; out-of-stock message
- [ ] 5.3 Cart page, cart-lines fragment, mini-cart fragment with `hx-swap-oob`; header slot partial embedding the mini-cart
- [x] 5.4 No-JS path: plain POST redirects back
- [x] 5.5 Tests: crawler creates no cart, stale cookie, quantity update returns lines + mini-cart

## 6. Checkout

- [x] 6.1 Step machine derived from the cart; email, address (`address_co`, `address_us`, fallback), shipping steps
- [x] 6.2 Payment step: providers for the region, renderer registry with `pp_system_default` → manual; hide and log-once unknown providers
- [x] 6.3 Complete: order → clear cookie, confirmation page; cart → error, keep cookie; empty cart → redirect to PLP
- [x] 6.4 `hx-disabled-elt` on complete; already-completed cart treated as success

## 7. Cache purge from Medusa

- [x] 7.1 Medusa subscriber for product, variant, category, collection and price events calling the site purge with the shared token, debounced 5 s
- [x] 7.2 Compose: pass the purge URL and token to the `medusa` service

## 8. Themes

- [x] 8.1 Default pages and fragments under `pages/commerce/`; theme override test for `pdp.html` (flat names; see design D10)
- [x] 8.2 `gositetest` helper rendering all commerce pages of a theme against fixtures
- [x] 8.3 Document fragment IDs and form field names in `CORE_API.md`

## 9. Verification

- [ ] 9.1 analytics-draft-v2: demo product through PLP → PDP → cart → manual checkout → order in Medusa Admin
- [ ] 9.2 Custom paths (`/shop`, `/p`), price change reflected after purge, crawler run creates no carts
- [ ] 9.3 Measure p95 of the PDP island locally and record it
