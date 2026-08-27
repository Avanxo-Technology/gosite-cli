## ADDED Requirements

### Requirement: The cache can purge a set of related keys

The cache SHALL support purging every key belonging to a group, not only keys
named one by one. Purging a group SHALL clear both the fresh and the stale copy
of each key, as purging a single key already does.

#### Scenario: Purging a blog's index pages

- **WHEN** a blog's index is cached across several pages and that blog's group
  is purged
- **THEN** every cached page of that index is cleared, fresh and stale

#### Scenario: Purge does not reach unrelated keys

- **WHEN** one blog's group is purged
- **THEN** cached pages of other blogs and the home page remain cached

#### Scenario: Nothing cached

- **WHEN** a group is purged and no key of that group is cached
- **THEN** the purge succeeds without error

### Requirement: Publishing an article invalidates exactly what it changes

Publishing, updating or unpublishing an article SHALL invalidate that article's
page and the index pages of its blog, because a new article changes what the
index lists.

#### Scenario: New article published

- **WHEN** an article is published
- **THEN** the index of its blog no longer serves a cached page that omits it

#### Scenario: Existing article edited

- **WHEN** a published article's body is edited
- **THEN** its own page reflects the edit without waiting for the cache to
  expire

#### Scenario: Article unpublished

- **WHEN** a published article is set back to draft
- **THEN** its page stops being served from the cache and answers 404, and it
  disappears from its blog's index

#### Scenario: Home page untouched

- **WHEN** an article is published and the home page does not list articles
- **THEN** the cached home page is not discarded

### Requirement: Purging remains authenticated and fail-closed

Extending purge to more keys SHALL NOT weaken its authentication. A purge
request that is not authenticated SHALL be refused, and a missing token SHALL
NOT be treated as "no authentication required".

#### Scenario: Unauthenticated purge

- **WHEN** a purge is requested without valid credentials
- **THEN** it is refused and nothing is purged

#### Scenario: Token not configured

- **WHEN** no purge token is configured in a non-development environment
- **THEN** the endpoint refuses the request rather than purging

### Requirement: A purge failure is visible

When a purge cannot complete, the caller SHALL be told, rather than the failure
being silently swallowed and stale content served on indefinitely.

#### Scenario: Cache backend unreachable during purge

- **WHEN** the cache backend cannot be reached while purging
- **THEN** the request reports the failure
