## ADDED Requirements

### Requirement: Cockpit does not hold the catalogue
The Cockpit `Commerce` addon SHALL read products from the Medusa API at request time and SHALL NOT create models that copy products, prices, stock or orders.

#### Scenario: Product picked
- **WHEN** an editor picks a product in a Cockpit entry
- **THEN** the entry stores the product's handle and nothing else about it

### Requirement: Products page in Cockpit
The addon SHALL provide a Cockpit page that lists the store's products from the Medusa Admin API, including drafts, with thumbnail, title, handle, status, price and inventory, with search by title and pagination, and SHALL NOT offer editing there.

#### Scenario: Editor browses products
- **WHEN** an editor opens the Commerce page in Cockpit
- **THEN** the products currently in Medusa are listed, and each row links to that product in Medusa Admin on the commerce domain

#### Scenario: Medusa unreachable
- **WHEN** the Medusa service is down
- **THEN** the page shows an error message and the rest of Cockpit keeps working

### Requirement: Product picker field
The addon SHALL provide a field type that searches the store's products through the Medusa API and stores the chosen handles, single or multiple, so a project can use it in its own collections and singletons.

#### Scenario: Featured products singleton
- **WHEN** a project defines a singleton with a multiple product field and an editor picks three products
- **THEN** the singleton stores three handles in the chosen order

### Requirement: Extended product data belongs to the project
Additional product data (editorial blocks, extra attributes, landing content) SHALL be modelled by each project as its own Cockpit collections or singletons that reference products by handle, and the addon SHALL NOT ship such models.

#### Scenario: Project extends products
- **WHEN** a project creates a `product_extras` collection with a product field and a rich-text field
- **THEN** its PDP template can load the entry for the current handle and render it, with no change to the addon

### Requirement: Link to the store admin
The addon SHALL show a link to the store's Medusa Admin in Cockpit's menu, on the site's `shop.` subdomain.

#### Scenario: Editor opens the store
- **WHEN** an editor clicks the store link
- **THEN** Medusa Admin opens on `shop.<site domain>/app`

### Requirement: Rendering picked products
Templates SHALL be able to render products from stored handles with live price and stock, skipping handles that no longer exist or are unpublished.

#### Scenario: Deleted product
- **WHEN** a picked product is deleted in Medusa Admin
- **THEN** pages that picked it render the remaining products without error
