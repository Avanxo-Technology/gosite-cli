## ADDED Requirements

### Requirement: The CMS client reads collections

`internal/cms` SHALL expose reading items from a Cockpit collection with
filtering, sorting, pagination and populate depth, alongside the existing
singleton read. Callers SHALL NOT construct Cockpit URLs or parse Cockpit
responses themselves.

#### Scenario: Reading a page of items

- **WHEN** the caller asks for items of a model with a filter, a sort order and
  a page size
- **THEN** it receives the matching items and the information needed to decide
  whether a next page exists

#### Scenario: Model has no items

- **WHEN** the requested model exists but matches no items
- **THEN** the caller receives an empty result and no error

### Requirement: Both Cockpit response shapes decode to one result type

The client SHALL send `skip` and `limit` on every collection read so the
response shape is deterministic, and SHALL still decode both shapes correctly.
Cockpit returns a bare JSON array from `GET /api/content/items/{model}`, but
returns a `{data, meta}` object when `skip` and `limit` are both present.

A wrapper object SHALL NOT be mistaken for a list of items.

#### Scenario: Wrapper response

- **WHEN** Cockpit returns `{"data": [...], "meta": {...}}`
- **THEN** the client returns the items from `data` and the total from `meta`

#### Scenario: Bare array response

- **WHEN** Cockpit returns a bare array
- **THEN** the client returns those items and reports a total equal to the
  number of items returned, without error

#### Scenario: Wrapper is never read as a list

- **WHEN** a wrapper response is decoded
- **THEN** the result never contains synthetic items lacking an `_id`

### Requirement: Total is optional, paging is not

Pagination SHALL work whether or not Cockpit reports a total. When no total is
available the client SHALL still report whether a further page exists.

#### Scenario: Total reported

- **WHEN** the response carries a total
- **THEN** the caller can render an exact page count

#### Scenario: Total absent

- **WHEN** the response carries no total
- **THEN** the caller can still determine that a next page exists, and renders
  next/previous navigation without an exact count

### Requirement: Unpublished entries are never served

The client SHALL rely on Cockpit's core read API, which restricts results to
published entries. The client SHALL NOT provide a way for the public site to
request unpublished entries.

#### Scenario: Draft article

- **WHEN** an article is saved as a draft in Cockpit
- **THEN** no page served by the Go app can render it

### Requirement: A failed read does not poison the cache

A failed read SHALL be distinguishable from a legitimately empty result, so a
failed render is discarded rather than cached instead of being served as an
empty page.

#### Scenario: CMS unreachable while rendering

- **WHEN** the CMS cannot be reached during a cold render of an article page
- **THEN** an error is returned, the render is discarded, and no empty page is
  stored in the cache
