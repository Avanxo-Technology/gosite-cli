## ADDED Requirements

### Requirement: Blog category pages
The blog addon SHALL serve `GET /:blog/category/:slug` as the blog index filtered to the articles whose `category` is the `blogCategories` entry with that slug, with the category in the page data as `Category`, and SHALL answer 404 when the blog or the category does not exist.

#### Scenario: Known category
- **WHEN** a visitor opens `/articulos/category/maquinaria` and the category exists
- **THEN** the index lists only that category's published articles and the page title names the category

#### Scenario: Unknown category
- **WHEN** the category slug matches no entry
- **THEN** the answer is 404

### Requirement: Article reading time and related articles
The article page data SHALL include `ReadingTime`, the minutes needed to read the body at 200 words per minute, rounded up and at least 1, counting only text outside HTML tags. It SHALL also include `Related`: up to 3 published articles of the same category, newest first, without the article itself, and empty when the article has no category.

#### Scenario: Article with a category
- **WHEN** an article has a category with four other published articles
- **THEN** `Related` holds the three newest of them

#### Scenario: Short article
- **WHEN** the body has 50 words
- **THEN** `ReadingTime` is 1

### Requirement: Blog routes accept a trailing slash
Every blog route SHALL also answer with a trailing slash (`/:blog/`, `/:blog/:slug/`, `/:blog/category/:slug/`) with the same status and content as without it.

#### Scenario: Old WordPress link
- **WHEN** a visitor opens `/articulos/mi-articulo/`
- **THEN** the article is served as at `/articulos/mi-articulo`

### Requirement: Blog pages carry the site's template data
When the `App` implements `TemplateDataer`, the blog's pages SHALL get that data, and the blog's own keys SHALL win over a key with the same name.

#### Scenario: Site chrome on the blog
- **WHEN** a site's `TemplateData` returns `Header` and `Footer`
- **THEN** the blog index and article templates can read `.Header` and `.Footer`

### Requirement: Blog in the sitemap
`/sitemap.xml` SHALL list the index of every blog and each published article, an article with its last-modified time.

#### Scenario: Published article
- **WHEN** the `articulos` blog has a published article `mi-articulo`
- **THEN** the sitemap lists `/articulos` and `/articulos/mi-articulo` with the article's `<lastmod>`
