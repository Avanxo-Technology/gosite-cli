## ADDED Requirements

### Requirement: Configurable store routes
When `Commerce` is enabled the site SHALL serve the PLP at `commerce_plp_path`, the PDP at `commerce_pdp_path/:handle` and the checkout at `commerce_checkout_path`, defaulting to `/tienda`, `/producto` and `/checkout`.

#### Scenario: Defaults
- **WHEN** `gosite.yml` lists `Commerce` and sets no path keys
- **THEN** `/tienda` lists the published products and `/producto/<handle>` shows the demo product

#### Scenario: Custom names
- **WHEN** `gosite.yml` sets `commerce_plp_path: /shop` and `commerce_pdp_path: /p`
- **THEN** `/shop` and `/p/<handle>` serve the store and `/tienda` is not a store route

#### Scenario: Colliding paths
- **WHEN** two commerce path keys have the same value, or a path does not start with `/`
- **THEN** startup fails with an error naming the keys

### Requirement: Product listing
The PLP SHALL list the products published in the site's sales channel with title, thumbnail, price in the region's currency and a link to the PDP, and SHALL support filtering by category and pagination.

#### Scenario: Category filter
- **WHEN** a visitor opens the PLP with `?category=<handle>`
- **THEN** only products in that category are listed

### Requirement: Product detail
The PDP SHALL show the product's title, images, description, options and variants, and SHALL respond 404 for a handle that is unknown or not published in the sales channel.

#### Scenario: Variant choice
- **WHEN** a visitor selects a variant on the PDP
- **THEN** the price, stock status and add-to-cart form update without a full page load

#### Scenario: Unknown handle
- **WHEN** a visitor opens the PDP with a handle that does not exist
- **THEN** the site responds 404 with the theme's not-found page

### Requirement: Cached pages with live islands
PLP and PDP HTML SHALL be served from the page cache, while price, stock, the add-to-cart form and the mini-cart SHALL be fetched as uncached fragments, and cache keys for commerce pages SHALL include the region.

#### Scenario: Price changed
- **WHEN** a price changes in Medusa Admin
- **THEN** the next PDP view shows the new price without waiting for the cache to expire

### Requirement: Cache purge from Medusa
The commerce service SHALL call the site's purge endpoint when a product, variant, price, collection or category is created, updated or deleted.

#### Scenario: Product unpublished
- **WHEN** a store owner unpublishes a product
- **THEN** the product is gone from the PLP on the next request

### Requirement: Server-side cart
The site SHALL hold the cart only as a Medusa cart referenced by an httpOnly, SameSite=Lax cookie containing the cart id and region, SHALL create the cart on the first add rather than on a page view, and the browser SHALL NOT call the Store API or see the publishable key.

#### Scenario: First add
- **WHEN** a visitor without a cart cookie adds a variant
- **THEN** a cart is created in the site's region, the line item is added, the cookie is set and the mini-cart fragment shows one item

#### Scenario: Crawler
- **WHEN** a client without cookies requests every PLP and PDP URL
- **THEN** no cart is created

#### Scenario: Stale cookie
- **WHEN** the cookie names a cart that no longer exists, is completed, or belongs to another region
- **THEN** the site discards the cookie and the next add creates a new cart

#### Scenario: Out of stock
- **WHEN** a visitor adds more units than the variant has in stock
- **THEN** the cart is unchanged and the fragment shows an out-of-stock message

### Requirement: Cart updates without page loads
Adding, changing the quantity of and removing line items SHALL be htmx requests that return the updated fragment and update the mini-cart in the same response, and every form SHALL still work as a plain POST without JavaScript.

#### Scenario: Quantity change
- **WHEN** a visitor changes a line item's quantity in the cart
- **THEN** the line, the totals and the mini-cart count update in one response

#### Scenario: No JavaScript
- **WHEN** a visitor without JavaScript submits the add-to-cart form
- **THEN** the item is added and the site redirects back to the PDP

### Requirement: Guest checkout
The checkout SHALL run email, address, shipping, payment and complete as successive server-rendered steps against the cart, without requiring an account, and SHALL show a confirmation page with the order number when Medusa returns an order.

#### Scenario: Manual payment end to end
- **WHEN** a visitor buys the demo product and chooses the manual provider
- **THEN** an order exists in Medusa Admin, the cart cookie is cleared and the confirmation page shows the order number

#### Scenario: Completion fails
- **WHEN** Medusa answers the complete request with a cart instead of an order
- **THEN** the cookie is kept, no confirmation is shown and the payment step shows the error

#### Scenario: Empty cart
- **WHEN** a visitor opens the checkout without items
- **THEN** the site redirects to the PLP

### Requirement: Payment options from the region
The payment step SHALL list the providers Medusa enables for the cart's region and SHALL show only those the site can render, logging a warning for the others.

#### Scenario: Unrenderable provider
- **WHEN** the region has a provider with no renderer in the site
- **THEN** it is not shown and a warning naming it is logged once

### Requirement: Theme-overridable pages
Every commerce page and fragment SHALL be an addon page that a theme replaces by shipping a file of the same name.

#### Scenario: Custom PDP
- **WHEN** a theme ships `pages/commerce/pdp.html`
- **THEN** the PDP uses the theme's template and the islands keep working
