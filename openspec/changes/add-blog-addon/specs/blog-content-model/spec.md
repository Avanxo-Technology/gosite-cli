## ADDED Requirements

### Requirement: The addon self-installs its content models

The Blog addon SHALL create its content models on first admin load without any
manual setup, and SHALL NOT overwrite a model that already exists.

The models are `blogs`, `blogPosts`, `blogCategories` and `blogAuthors`, all
declared with `'group' => 'Blog'` so Cockpit clusters them in the Content
sidebar.

#### Scenario: Fresh installation

- **WHEN** an administrator opens the Cockpit admin for the first time after the
  addon is installed
- **THEN** the four models exist with their declared fields, and no manual step
  was required

#### Scenario: A model of the same name already exists

- **WHEN** the project already has a model named `blogPosts`
- **THEN** the addon leaves it untouched and does not alter its fields

#### Scenario: Model names do not collide with a client's own models

- **WHEN** the project already has models named `categories` and `authors` for
  unrelated content
- **THEN** the addon still creates `blogCategories` and `blogAuthors`, and the
  blog reads neither of the pre-existing models

### Requirement: Articles reference blogs, categories and authors

`blogPosts` SHALL hold the article content and SHALL reference the supporting
collections rather than duplicating their data. A site with several blogs is
served by adding items to `blogs`, never by creating additional models.

#### Scenario: Adding a second blog

- **WHEN** an editor adds an item to `blogs`
- **THEN** articles can be assigned to it, and no schema change or model
  creation is needed

#### Scenario: Schema is identical across projects

- **WHEN** the addon is installed into any two gosite projects
- **THEN** the field definitions of all four models are identical

### Requirement: Every article has a URL-safe slug unique within its blog

`blogPosts` SHALL carry a slug used as the article's public URL segment. The
slug SHALL contain only lowercase letters, digits and hyphens, with accented
characters transliterated (`diseño-gráfico` becomes `diseno-grafico`).

The slug SHALL be unique within its blog. Two articles in different blogs may
share a slug.

#### Scenario: Slug derived from the title

- **WHEN** an editor saves an article with a title and an empty slug
- **THEN** a slug is derived from the title, transliterated and lowercased

#### Scenario: Slug collision within the same blog

- **WHEN** an editor saves an article whose slug already exists in the same blog
- **THEN** the save is rejected with a message naming the conflict, or the slug
  is suffixed to make it unique — never silently accepted as a duplicate

#### Scenario: Same slug in a different blog

- **WHEN** an editor saves an article with slug `novedades` in blog "Casos" and
  an article with that slug already exists in blog "Noticias"
- **THEN** the save succeeds

### Requirement: The published byline falls back to the editing user

The article's byline SHALL come from its `blogAuthors` reference when set. When
that reference is empty, the byline SHALL fall back to the Cockpit user who
created the article (`_by`), resolved to a `blogAuthors` item linked to that
account.

Fields of the underlying Cockpit user account that are not part of a byline —
e-mail and any credential field — SHALL NOT be exposed through any public
response.

#### Scenario: Explicit author set

- **WHEN** an article has a `blogAuthors` reference
- **THEN** that author is the byline, regardless of who edited the article

#### Scenario: Author left empty

- **WHEN** an article has no author reference and was created by a Cockpit user
  linked to a `blogAuthors` item
- **THEN** that linked author is used as the byline

#### Scenario: No author and no link

- **WHEN** an article has no author reference and `_by` resolves to no
  `blogAuthors` item
- **THEN** the article renders without a byline rather than failing to render

#### Scenario: User account fields are not leaked

- **WHEN** a byline is resolved from a Cockpit user account
- **THEN** the response carries only display fields, and never the account's
  e-mail address

### Requirement: The admin screen shows what Cockpit's editor cannot

The addon SHALL provide an admin screen at `/blog`, reachable from the Modules
menu and gated by a `blog/manage` permission exposed in Settings > Roles.

For each article the screen SHALL show its publication state and a link to the
article's real public URL on the Go site, and SHALL offer purging that
article's cache.

#### Scenario: Preview link points at the live site

- **WHEN** an administrator opens `/blog` and the project's public base URL is
  configured
- **THEN** each published article links to its address on the public site, not
  to a Cockpit route

#### Scenario: Base URL not configured

- **WHEN** the project's public base URL is not configured
- **THEN** the screen still lists the articles and reports that preview links
  are unavailable, rather than emitting broken links

#### Scenario: Permission enforced

- **WHEN** a user without `blog/manage` requests `/blog`
- **THEN** the request is refused and no article data is returned
