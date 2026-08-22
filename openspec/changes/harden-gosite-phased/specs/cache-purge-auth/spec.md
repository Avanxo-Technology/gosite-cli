## ADDED Requirements

### Requirement: Cache purge endpoint authenticates fail-closed

The `/cache/purge` endpoint in the generated Go application SHALL refuse to operate in any non-development environment unless a purge token is configured. A missing token MUST NOT be interpreted as "no authentication required".

#### Scenario: Production without a configured token

- **WHEN** the environment is not development and `COCKPIT_API_TOKEN` is empty
- **THEN** the endpoint responds HTTP 503
- **AND** the cache is not purged
- **AND** a warning naming the missing variable is logged at startup

#### Scenario: Production with a valid token

- **WHEN** the environment is not development, a token is configured, and the request carries a matching `X-Api-Key`
- **THEN** the cache is purged
- **AND** the endpoint responds HTTP 200

#### Scenario: Production with a wrong token

- **WHEN** the request carries an `X-Api-Key` that does not match the configured token
- **THEN** the endpoint responds HTTP 401
- **AND** the cache is not purged

#### Scenario: Token comparison resists timing analysis

- **WHEN** the supplied token is compared against the configured one
- **THEN** the comparison is constant-time

#### Scenario: Development convenience preserved

- **WHEN** the environment is development
- **THEN** the endpoint purges without requiring a token, so the on-page htmx button keeps working

### Requirement: Purge caller reports failures

The CachePurge addon SHALL NOT silently discard the outcome of a purge request. A failed purge MUST be logged with the HTTP status or transport error, while still never blocking the CMS save that triggered it.

#### Scenario: Purge endpoint returns an error status

- **WHEN** the purge POST returns HTTP 503
- **THEN** the addon logs the failing status and URL
- **AND** the originating CMS save completes successfully

#### Scenario: App unreachable

- **WHEN** the purge POST fails at the transport level
- **THEN** the curl error is logged
- **AND** the originating CMS save completes successfully

#### Scenario: App URL not configured

- **WHEN** `APP_URL` is empty
- **THEN** the addon logs once that purging is disabled
- **AND** no request is attempted
