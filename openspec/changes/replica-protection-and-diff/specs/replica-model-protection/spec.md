## ADDED Requirements

### Requirement: Protected models are configured per instance
Each Cockpit instance running Replica SHALL keep its own list of protected content models, stored outside the content collections so that replication cannot change it. The list SHALL be empty on a new install.

#### Scenario: New install has nothing protected
- **WHEN** Replica runs for the first time on an instance
- **THEN** the protected list is empty and every content model accepts replication writes as before

#### Scenario: Replication cannot change the list
- **WHEN** a source pushes every model and its assets to an instance that protects `seoPages`
- **THEN** the destination's protected list still contains `seoPages`

### Requirement: The protected list is edited in the admin screen
The Replica admin screen SHALL let a user with `replica/manage` mark and unmark each local content model as protected, and every change SHALL be appended to the activity log with the model, the new state and the user.

#### Scenario: Protect a model
- **WHEN** an admin switches `seoPages` to protected and saves
- **THEN** the list contains `seoPages` and the activity log has an entry naming `seoPages`, `protected` and that admin

#### Scenario: Missing permission
- **WHEN** a user without `replica/manage` calls the protected-list endpoint
- **THEN** the response is 403 and the list does not change

#### Scenario: Request without a valid CSRF token
- **WHEN** a change to the list arrives without a valid CSRF token
- **THEN** the change is refused and the list does not change

### Requirement: A protected model refuses replication writes
An instance SHALL refuse every replication write to a protected model — entries through `POST /api/replica/items/{model}` and definitions through `POST /api/replica/models` — with HTTP 423 and a body that names the protected models, and it SHALL write nothing for those models. Edits made in the instance's own Content editor SHALL NOT be affected.

#### Scenario: Entries refused
- **WHEN** a peer posts entries for `seoPages` and the destination protects `seoPages`
- **THEN** the response is 423, the body names `seoPages`, and no `seoPages` entry on the destination changes

#### Scenario: Definition refused
- **WHEN** a peer posts model definitions that include `seoPages` and `posts`, and only `seoPages` is protected
- **THEN** the response is 423 naming `seoPages`, and no definition is written

#### Scenario: Local editing still works
- **WHEN** an editor on the destination saves a `seoPages` entry in the Content editor
- **THEN** the entry is saved

### Requirement: The manifest advertises protected models
`GET /api/replica/manifest` SHALL include a `protected` array with the names of the protected models.

#### Scenario: Manifest lists protection
- **WHEN** a source reads the manifest of an instance that protects `webapp` and `seoPages`
- **THEN** the manifest contains `"protected": ["seoPages", "webapp"]`

### Requirement: Push skips protected models and continues
A push SHALL read the destination's protected list before it writes, SHALL not send entries or definitions for those models, SHALL count each one under `protected` in the result and the log, and SHALL continue with the remaining models. If the destination answers a write with 423 anyway, the push SHALL treat that model the same way.

#### Scenario: Mixed scope
- **WHEN** a target's scope is `posts` and `seoPages`, and the destination protects `seoPages`
- **THEN** `posts` is pushed, `seoPages` is not sent, and the result shows `protected: 1` with a message `seoPages: protected on the destination`

#### Scenario: Protection added during a run
- **WHEN** the destination protects `posts` after the source read the manifest but before it posts `posts`
- **THEN** the 423 is reported as `posts: protected on the destination`, not as a failed run

#### Scenario: Dry run
- **WHEN** a dry-run push includes a protected model
- **THEN** the plan lists that model as protected and plans no create or update for it

### Requirement: Pull does not write into a locally protected model
A pull SHALL not write entries or definitions into a model that is protected on the local instance, and SHALL report it the same way a push reports a protected destination. Reading from a model that is protected on the remote SHALL be allowed.

#### Scenario: Pull into a protected local model
- **WHEN** the local instance protects `seoPages` and a pull includes `seoPages`
- **THEN** no local `seoPages` entry changes and the result shows `seoPages: protected here`

#### Scenario: Pull from a protected remote model
- **WHEN** the remote protects `seoPages` and the local instance does not
- **THEN** the pull copies `seoPages` entries to the local instance

### Requirement: Destinations without protection support are flagged
When the destination is a peer whose manifest has no `protected` key, a push SHALL add the message `Destination Replica <version> does not support model protection` to the result. A core destination SHALL get a message saying that protection depends on the API key's role permissions.

#### Scenario: Old peer
- **WHEN** a push targets a peer running Replica 1.0.0
- **THEN** the result contains `Destination Replica 1.0.0 does not support model protection`

#### Scenario: Core destination
- **WHEN** a push targets an instance without Replica
- **THEN** the result contains a message that protection is not available and that the API key's role permissions are the only restriction
