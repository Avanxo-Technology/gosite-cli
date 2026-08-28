## ADDED Requirements

### Requirement: Layout template renders SEO tags automatically
The layout template SHALL render SEO meta tags for every page using the `seoTags` template function, without requiring pages to define a head block for SEO.

#### Scenario: Page with path provided
- **WHEN** a page is rendered with .Path="/about" and no .SEOData
- **THEN** the layout renders meta description, og:tags, twitter:tags from seoPages entry for "/about" or webapp defaults

#### Scenario: Page without path
- **WHEN** a page is rendered without .Path
- **THEN** the layout renders SEO tags using webapp defaults only

### Requirement: Layout template supports SEO data override
The layout template SHALL check for .SEOData and use it to override resolved SEO data when present.

#### Scenario: SEOData provided by handler
- **WHEN** a page is rendered with .SEOData={Title: "Custom", Description: "Custom desc"}
- **THEN** the layout renders meta tags using the override values

#### Scenario: SEOData not provided
- **WHEN** a page is rendered without .SEOData
- **THEN** the layout resolves SEO data from seoPages/webapp defaults

### Requirement: SEO template renders complete meta tags
The seoTags template function SHALL render a complete set of SEO meta tags: title, meta description, canonical, og:type, og:title, og:description, og:url, og:image, twitter:card, twitter:title, twitter:description, twitter:image, robots meta, JSON-LD script.

#### Scenario: Full SEO data
- **WHEN** seoTags is called with Data containing title, description, image, canonical, jsonLd, noIndex
- **THEN** the function renders all applicable meta tags

#### Scenario: Partial SEO data
- **WHEN** seoTags is called with Data containing only title and description
- **THEN** the function renders only the tags that have values (no empty tags)

#### Scenario: NoIndex flag
- **WHEN** seoTags is called with Data containing noIndex=true
- **THEN** the function renders `<meta name="robots" content="noindex, nofollow">`

### Requirement: Layout template renders favicon
The layout template SHALL render a `<link rel="icon">` tag using the favicon from the webapp singleton.

#### Scenario: Favicon configured
- **WHEN** the webapp singleton has a favicon asset
- **THEN** the layout renders `<link rel="icon" href="[favicon-url]">`

#### Scenario: Favicon not configured
- **WHEN** the webapp singleton has no favicon
- **THEN** the layout does not render a favicon link

### Requirement: Template function seoTags registered
The system SHALL register a `seoTags` template function in the renderer that accepts a path and optional SEOData override, resolves SEO data, and returns rendered HTML meta tags.

#### Scenario: seoTags function available
- **WHEN** a template calls {{seoTags .Path .SEOData}}
- **THEN** the function resolves SEO data and returns HTML meta tags as template.HTML

#### Scenario: seoTags with no arguments
- **WHEN** a template calls {{seoTags}}
- **THEN** the function uses empty path and no overrides, returning default SEO tags

### Requirement: Home page renders SEO tags
The home page template SHALL define a head block or rely on the layout's automatic SEO rendering to include SEO meta tags.

#### Scenario: Home page with path
- **WHEN** the home page is rendered with .Path="/"
- **THEN** the page includes SEO meta tags from seoPages entry for "/" or webapp defaults

#### Scenario: Home page without path (legacy)
- **WHEN** the home page is rendered without .Path (existing behavior)
- **THEN** the page renders SEO tags using webapp defaults only

### Requirement: Blog articles render SEO with overrides
Blog article templates SHALL pass .SEOData from the blog post's SEO fields to override resolved SEO data.

#### Scenario: Blog post with SEO fields
- **WHEN** a blog article is rendered with .SEOData from blog post's seoTitle, seoDescription, seoImage
- **THEN** the page renders SEO meta tags using the blog post's SEO fields

#### Scenario: Blog post without SEO fields
- **WHEN** a blog article is rendered with empty .SEOData
- **THEN** the page resolves SEO from seoPages or webapp defaults

### Requirement: robots.txt route serves webapp config
The system SHALL serve a GET /robots.txt route that returns the robotsTxt content from the webapp singleton.

#### Scenario: robots.txt configured
- **WHEN** a GET request is made to /robots.txt and the webapp singleton has robotsTxt="User-agent: *\nDisallow: /admin"
- **THEN** the system returns the robotsTxt content with Content-Type: text/plain

#### Scenario: robots.txt not configured
- **WHEN** a GET request is made to /robots.txt and the webapp singleton has empty robotsTxt
- **THEN** the system returns a default robots.txt allowing all crawlers

### Requirement: Favicon route redirects to asset
The system SHALL serve a GET /favicon.ico route that redirects to the favicon asset URL from the webapp singleton.

#### Scenario: Favicon configured
- **WHEN** a GET request is made to /favicon.ico and the webapp singleton has a favicon asset
- **THEN** the system returns a 301 redirect to the favicon asset URL

#### Scenario: Favicon not configured
- **WHEN** a GET request is made to /favicon.ico and the webapp singleton has no favicon
- **THEN** the system returns a 404 response
