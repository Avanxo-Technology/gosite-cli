## ADDED Requirements

### Requirement: A migrated site renders what the legacy site rendered
A legacy site migrated to thin SHALL answer every route captured before the migration with the same status code, the same `Cache-Control` and `X-Robots-Tag` headers, and a body that differs only in blank lines and in tags that core adds to `<head>`.

#### Scenario: Route comparison
- **WHEN** every captured route (pages, `robots.txt`, `sitemap.xml`, `llms.txt`, blog index and one article, a 404) is requested from the legacy build and from the thin build with the same CMS data
- **THEN** each pair matches under the rule above, and the comparison output is in the site's PR

#### Scenario: Purge reaches the new cache
- **WHEN** a canary key is written under `<project>:<env>:cache:` and `POST /cache/purge` is called with the token
- **THEN** the canary key is gone, and keys under `<project>:app:` are still there

### Requirement: Live Redis state is carried over
A migration SHALL list every Redis key the legacy site writes outside its cache, and SHALL either move each one into `State()` or record why it may be lost. A key that is moved SHALL be renamed at startup with `RENAMENX`, so its TTL is kept and a key already in the new place is never overwritten, and the old names SHALL be in one place in the code so that the rename can be reversed.

#### Scenario: avanxo scan leads
- **WHEN** the thin avanxo starts with a `scanlead:42` key that has 3 days left
- **THEN** `<project>:app:scanlead:42` exists with the same value and about 3 days left, and `scanlead:42` no longer exists

#### Scenario: Key already moved
- **WHEN** both the old and the new key exist at startup
- **THEN** the new key keeps its value, and the old key is left in place and logged

### Requirement: The migration is documented and changes no data
MIGRATIONS.md SHALL have a "legacy -> thin" section with the steps the pilot used. A migration SHALL NOT change Cockpit models, entries or assets, and SHALL NOT delete objects in MinIO. Every data step a deploy needs SHALL be in the site's PR as an owner action.

#### Scenario: A data step is needed
- **WHEN** a migration needs a value moved in Cockpit (for example avanxo's `dx_options` into `formSettings`)
- **THEN** the PR lists the step for the owner, and the site keeps working with the old value until the step is done
