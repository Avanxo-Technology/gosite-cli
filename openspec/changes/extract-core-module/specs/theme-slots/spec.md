## ADDED Requirements

### Requirement: Layouts use stable template slots
The core SHALL define the template slots `gosite:head`, `gosite:body-start` and `gosite:body-end`, and core features (SEO tags, analytics head and body tags, consent banner and link, and future features) SHALL render only through these slots so a layout that calls them needs no edit when core adds a feature.

#### Scenario: New core feature appears without layout change
- **WHEN** a site upgrades to a core version that adds output to `gosite:body-end`
- **THEN** that output appears in rendered pages and the theme's layout is unchanged

### Requirement: Themes override core partials by name
A template defined in the site's `theme/` with the same name as a core partial SHALL replace the core partial for every render, and core partials not overridden SHALL remain in effect.

#### Scenario: Override consent link
- **WHEN** `theme/partials/consent.html` defines `gosite:consent-link`
- **THEN** pages render the theme's link and all other core partials unchanged

### Requirement: Stable page view model
Every page template SHALL receive a documented `gosite.Page` value whose fields include `.Site`, `.SEO`, `.Content`, `.Consent` and `.Data`, where `.Content` SHALL always be a `map[string]any` and `.Data` holds values returned by the site's template-data extension.

#### Scenario: Content helper on CMS content
- **WHEN** a template passes `.Content` to a core helper that expects a map
- **THEN** the helper reads the values instead of rendering its fallback

### Requirement: Contract test helper
The core SHALL provide a `gositetest` package whose check renders every page of a site with its own templates and fails when a required slot is missing, a slot is called more than once, or a page fails to execute.

#### Scenario: Duplicate slot call
- **WHEN** a layout calls `gosite:body-end` twice and the site's tests run the `gositetest` check
- **THEN** the test fails naming the layout and the slot
