## ADDED Requirements

### Requirement: SEO package reads webapp singleton
The system SHALL provide a `ReadWebappConfig()` function that reads the webapp singleton from Cockpit and returns a WebappConfig struct with favicon, llmText, robotsTxt, defaultTitle, defaultDescription, defaultImage.

#### Scenario: Webapp config read successfully
- **WHEN** ReadWebappConfig() is called and the webapp singleton exists
- **THEN** the system returns a WebappConfig struct with all fields populated from the singleton

#### Scenario: Webapp singleton not found
- **WHEN** ReadWebappConfig() is called and the webapp singleton does not exist
- **THEN** the system returns a WebappConfig struct with empty fields (no error)

### Requirement: SEO package looks up seoPages by path
The system SHALL provide a `LookupPage(path string)` function that queries the seoPages collection for an entry matching the given path.

#### Scenario: SEO page found
- **WHEN** LookupPage("/about") is called and a seoPages entry with path="/about" exists
- **THEN** the system returns a Data struct with the entry's SEO fields

#### Scenario: SEO page not found
- **WHEN** LookupPage("/unknown") is called and no seoPages entry matches
- **THEN** the system returns nil

### Requirement: SEO package resolves data with fallback chain
The system SHALL provide a `Resolve(path string, overrides ...*Data)` function that merges SEO data from multiple sources: (1) webapp singleton defaults, (2) seoPages entry for path, (3) content-specific overrides.

#### Scenario: No overrides, no seoPages entry
- **WHEN** Resolve("/") is called with no overrides and no seoPages entry for "/"
- **THEN** the system returns Data with webapp singleton default values

#### Scenario: seoPages entry overrides defaults
- **WHEN** Resolve("/about") is called and a seoPages entry exists with title="About Us"
- **THEN** the system returns Data with title="About Us" and other fields from webapp defaults

#### Scenario: Override overrides seoPages
- **WHEN** Resolve("/blog/my-post", &Data{Title: "Custom"}) is called and a seoPages entry exists with title="Blog Post"
- **THEN** the system returns Data with title="Custom" (override wins over seoPages)

#### Scenario: Empty override fields do not override
- **WHEN** Resolve("/blog/my-post", &Data{Title: "Custom", Description: ""}) is called
- **THEN** the system returns Data with title="Custom" and description from seoPages or defaults (empty string does not override)

### Requirement: SEO package caches resolved data in Redis
The system SHALL cache resolved SEO data in Redis with a TTL of 5 minutes, keyed by path.

#### Scenario: Cache hit
- **WHEN** Resolve("/about") is called and a cached entry exists for "/about"
- **THEN** the system returns the cached data without querying Cockpit

#### Scenario: Cache miss
- **WHEN** Resolve("/about") is called and no cached entry exists
- **THEN** the system queries Cockpit, caches the result, and returns it

#### Scenario: Cache invalidated on content save
- **WHEN** a seoPages entry is saved via the admin API
- **THEN** the system purges the cache entry for that path

### Requirement: SEO package provides FromBlogPost helper
The system SHALL provide a `FromBlogPost(post map[string]any)` function that creates SEO Data overrides from a blog post's SEO fields (seoTitle, seoDescription, seoImage, seoJsonLd, seoCanonical, seoNoIndex).

#### Scenario: Blog post with SEO fields
- **WHEN** FromBlogPost is called with a post containing seoTitle="Custom Title" and title="Post Title"
- **THEN** the system returns Data with Title="Custom Title"

#### Scenario: Blog post with empty SEO fields
- **WHEN** FromBlogPost is called with a post containing empty seoTitle and title="Post Title"
- **THEN** the system returns Data with Title="" (empty, so fallback chain continues)

### Requirement: SEO package initializes on app startup
The system SHALL initialize the SEO package in app.go, making it available to all handlers via the Handlers struct.

#### Scenario: SEO package initialized
- **WHEN** the app starts
- **THEN** the system creates a SEO instance with CMS client and cache connection

#### Scenario: SEO package available to handlers
- **WHEN** a handler calls h.SEO.Resolve(path)
- **THEN** the system returns the resolved SEO data

### Requirement: SEO package reads seoPages collection
The system SHALL query the seoPages collection from Cockpit via REST API to find SEO data for specific paths.

#### Scenario: Collection query
- **WHEN** LookupPage("/about") is called
- **THEN** the system makes a REST request to Cockpit's content/items/seoPages endpoint with filter[path]="/about"

#### Scenario: Collection query with no results
- **WHEN** LookupPage("/unknown") is called and no matching entry exists
- **THEN** the system returns nil (not an error)
