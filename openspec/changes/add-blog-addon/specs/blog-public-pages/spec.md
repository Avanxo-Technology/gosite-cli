## ADDED Requirements

### Requirement: Each blog has an index page and articles addressed by slug

The Go app SHALL serve a blog index at `/{blog}` and an article at
`/{blog}/{slug}`, where `{blog}` is a blog's slug and `{slug}` is the article's
slug within that blog.

#### Scenario: Blog index

- **WHEN** a visitor requests `/noticias` and a blog with slug `noticias` exists
- **THEN** the published articles of that blog are listed, newest first

#### Scenario: Article detail

- **WHEN** a visitor requests `/noticias/mi-post`
- **THEN** the article with slug `mi-post` in blog `noticias` is rendered

#### Scenario: Same slug in two blogs

- **WHEN** `/noticias/novedades` and `/casos/novedades` are both requested and
  both articles exist
- **THEN** each request renders the article belonging to its own blog

#### Scenario: Unknown blog

- **WHEN** a visitor requests `/no-existe` and no blog has that slug
- **THEN** the response is 404

#### Scenario: Unknown article in an existing blog

- **WHEN** a visitor requests `/noticias/no-existe`
- **THEN** the response is 404, not the blog index

#### Scenario: Draft article requested directly

- **WHEN** a visitor requests the URL of an article that is not published
- **THEN** the response is 404

### Requirement: Blog routes never shadow the rest of the site

An existing or future route of the project SHALL take precedence over the blog
route, and blog slugs SHALL NOT be allowed to occupy a path the application
already serves. Serving blogs from the root means `/{blog}` sits where every
other page of the site also lives.

#### Scenario: A project page shares a path with a blog slug

- **WHEN** the project serves `/contacto` and a blog also has the slug
  `contacto`
- **THEN** `/contacto` renders the project's page, not the blog index

#### Scenario: Reserved path rejected at the CMS

- **WHEN** an editor tries to save a blog whose slug is one of the paths the
  scaffold reserves (`static`, `storage`, `healthz`, `cache`, `api`)
- **THEN** the save is refused with a message naming the conflict

#### Scenario: Infrastructure routes keep working

- **WHEN** the blog routes are mounted and `/healthz`, `/cache/purge` and
  `/static/...` are requested
- **THEN** each behaves exactly as before the blog existed

### Requirement: Index pages are paginated

The blog index SHALL page through articles rather than rendering the whole
collection, and SHALL offer navigation to the next and previous page.

#### Scenario: More articles than fit on a page

- **WHEN** a blog holds more articles than the page size
- **THEN** the first page shows the newest ones and links to the next page

#### Scenario: Last page

- **WHEN** a visitor is on the final page
- **THEN** no next-page link is offered

#### Scenario: Page beyond the end

- **WHEN** a visitor requests a page number past the last page
- **THEN** the response is 404 rather than an empty index

### Requirement: Blog pages carry SEO metadata

Every blog page SHALL emit a title, a meta description and Open Graph tags
describing that specific page, so an article shared on social media previews
correctly and search engines index it distinctly.

#### Scenario: Article metadata

- **WHEN** an article page is rendered
- **THEN** its title, description and Open Graph tags describe that article,
  including its cover image when one is set

#### Scenario: Article without a cover image

- **WHEN** an article has no cover image
- **THEN** the page still renders with valid metadata and no empty image tag

#### Scenario: Canonical address

- **WHEN** an article page is rendered
- **THEN** it declares its canonical URL at `/{blog}/{slug}`

### Requirement: Blog pages exist in both template flavors

The index and article templates SHALL ship for both the `plain` and `tailwind`
flavors, so a scaffold created with either flavor has working blog pages.

#### Scenario: Tailwind scaffold

- **WHEN** a project is created with the tailwind flavor and the Blog addon
- **THEN** the blog pages render styled with the flavor's conventions

#### Scenario: Plain scaffold

- **WHEN** a project is created with the plain flavor and the Blog addon
- **THEN** the blog pages render with the flavor's stylesheet and no Tailwind
  classes

### Requirement: Blog pages are served through the cache

Blog pages SHALL use the same cache-aside path as the home page, so a cache hit
costs no CMS call, and a failed render SHALL NOT be cached.

#### Scenario: Second request for the same article

- **WHEN** an article page is requested twice within the cache window
- **THEN** the second request is served from the cache without contacting the
  CMS

#### Scenario: Development mode

- **WHEN** the app runs in development
- **THEN** blog pages bypass the cache like every other page
