## ADDED Requirements

### Requirement: One commerce service per site and environment
A thin site that lists `Commerce` in `gosite.yml` SHALL run its own Medusa v2 service from the `gosite-medusa` image at the site's core version, with its own Postgres and Redis, declared in each of its generated compose files (dev, QA and prod), and no other site or environment SHALL share them.

#### Scenario: Store enabled
- **WHEN** `gosite.yml` lists `Commerce` and the user runs `gosite generate`
- **THEN** `docker-compose.yml`, `docker-compose.qa.yml` and `docker-compose.prod.yml` each contain the `medusa`, `medusa-db` and `medusa-redis` services for that project, and the Medusa image tag equals the core version

#### Scenario: QA and prod are separate stores
- **WHEN** the same site is deployed from its QA and prod compose files
- **THEN** each deployment has its own Medusa, database and volumes, and an order placed in QA does not exist in prod

#### Scenario: Two stores on one host
- **WHEN** two sites on the same host enable `Commerce`
- **THEN** each has its own containers, volumes and database, and neither can read the other's carts or orders

### Requirement: Medusa Admin is the commerce back office
The catalog, categories, collections, prices, stock, promotions and orders SHALL be managed in Medusa's own Admin, and gosite SHALL NOT store copies of them in Cockpit or Mongo.

#### Scenario: Product edited
- **WHEN** a store owner changes a product's price in Medusa Admin
- **THEN** Medusa is the only system whose data changed

### Requirement: Idempotent seed
On every start the commerce service SHALL ensure that the region named by `commerce_region`, a sales channel, a stock location, a shipping option, the manual payment provider on that region, a publishable API key and one demo product exist, creating only what is missing and never modifying or deleting existing records.

#### Scenario: First start
- **WHEN** the service starts against an empty database with `commerce_region: co`
- **THEN** a region with currency COP and country CO exists, the manual payment provider is enabled on it, and a published demo product with one variant priced in COP and stock in the location can be added to a cart through the Store API

#### Scenario: Restart after edits
- **WHEN** the store owner renamed the demo product and the service restarts
- **THEN** the seed creates nothing new and the renamed product keeps its name

#### Scenario: Demo product deleted
- **WHEN** the store owner deleted the demo product and the service restarts
- **THEN** the seed does not recreate it

#### Scenario: Unsupported region
- **WHEN** `commerce_region` is not one of the supported codes (`co`, `us`)
- **THEN** the service fails to start with an error naming the value and the supported codes

### Requirement: Publishable key handoff
The seed SHALL write the publishable API key of the site's sales channel to a file on a volume shared with the site container, and the site SHALL read the key from that file, so no one copies the key by hand.

#### Scenario: Fresh deploy
- **WHEN** a new store is deployed and the seed finishes
- **THEN** the key file exists on the shared volume and holds a key the Store API accepts

### Requirement: Exposure
The Medusa Admin (`/app`), the admin API it uses and payment webhooks (`/hooks/*`) SHALL be reachable on the site's `shop.` subdomain, and the Store API SHALL be reachable only from the site container over the project network.

#### Scenario: Browser calls the Store API
- **WHEN** a browser requests `/store/products` on the `shop.` subdomain
- **THEN** the request is refused, and the same request from the site container succeeds

### Requirement: Abandoned cart cleanup
The commerce service SHALL delete carts that were never completed and were last updated more than `COMMERCE_CART_TTL_DAYS` days ago (default 30), and SHALL NOT touch completed carts or orders.

#### Scenario: Old anonymous cart
- **WHEN** the cleanup job runs and an uncompleted cart was last updated 31 days ago
- **THEN** that cart is deleted and every order is unchanged
