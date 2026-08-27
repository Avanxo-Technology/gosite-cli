## ADDED Requirements

### Requirement: The blog installs into an existing project

Installing the blog into a project that already exists SHALL deliver both
halves — the Cockpit addon and the Go-side pages — through gosite's existing
addon install path, without the operator copying files by hand.

#### Scenario: Installing into an existing project

- **WHEN** an operator installs the Blog addon into an existing project
- **THEN** the Cockpit addon and the Go blog package, templates and example
  pages are all present afterwards

#### Scenario: Re-running the install

- **WHEN** the install is run a second time on the same project
- **THEN** it refreshes the managed files and reports what it changed, without
  duplicating routes or content

#### Scenario: New scaffolds

- **WHEN** a project is created with the Blog addon selected
- **THEN** the blog works with no additional install step

### Requirement: Files the project owns are never overwritten

`router.go` and any file the project has edited by hand SHALL NOT be
overwritten by the install. The blog SHALL be mounted from a package of its own
so that the project's routing file needs at most one added line.

#### Scenario: Hand-edited router

- **WHEN** the project's `router.go` has been edited since it was scaffolded
- **THEN** the install does not overwrite it

#### Scenario: Mount line cannot be added automatically

- **WHEN** the install cannot insert the mount line safely
- **THEN** it completes the rest of the install and tells the operator the
  exact line to add and where, rather than failing or guessing

#### Scenario: Mount line already present

- **WHEN** the mount line is already in `router.go`
- **THEN** the install does not add a second one

#### Scenario: Hand-edited blog template

- **WHEN** an operator has customised a blog page template and re-runs the
  install
- **THEN** the customised file is preserved and reported, consistent with how
  sync already treats hand-edited files

### Requirement: The operator is told what makes the install take effect

The install SHALL state what has to be rebuilt for the change to become
visible, because restarting is not enough: the addon is baked into the CMS
image, and the Go pages are compiled into the application.

#### Scenario: Install finishes

- **WHEN** the install completes on an existing project
- **THEN** it states that the CMS image and the application must be rebuilt

### Requirement: Installing the blog does not disturb the rest of the project

The install SHALL be scoped to what the blog needs. It SHALL NOT modify
compose files, environment files, other addons, or unrelated application code.

#### Scenario: Unrelated files untouched

- **WHEN** the blog is installed into an existing project
- **THEN** `docker-compose.prod.yml`, `.env`, and other addons are unchanged

#### Scenario: A project that does not want the blog

- **WHEN** a project without the Blog addon is synced
- **THEN** no blog models, routes or templates appear in it
