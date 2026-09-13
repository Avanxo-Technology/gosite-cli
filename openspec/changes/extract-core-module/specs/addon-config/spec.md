## ADDED Requirements

### Requirement: Addons are declared in gosite.yml
A thin site's enabled addons SHALL be the `addons` list in `gosite.yml`, and at startup `gosite.Run` SHALL enable the Go half (routes, templates, purge behaviour) of each listed addon from the core module.

#### Scenario: Blog enabled
- **WHEN** `gosite.yml` lists `Blog`
- **THEN** the blog routes and templates are active without any blog source file in the site

#### Scenario: Unknown addon
- **WHEN** `gosite.yml` lists a name that is not a gosite addon
- **THEN** startup fails with an error naming the unknown addon and the available ones

### Requirement: CLI manages addons through gosite.yml
For thin sites, `gosite addons list [project]` SHALL show gosite's addon library and which addons the project enables, `gosite addons add <name>...` SHALL add them to `gosite.yml` after checking `REQUIRES`, and `gosite addons remove <name>...` SHALL remove them from `gosite.yml`, all without copying or deleting addon source in the project.

#### Scenario: Add an addon
- **WHEN** a user runs `gosite addons add Forms my-site`
- **THEN** `Forms` is appended to `addons` in `my-site/gosite.yml` and the CLI tells the user to run `gosite sync` and restart

#### Scenario: Remove keeps content
- **WHEN** a user runs `gosite addons remove Blog my-site`
- **THEN** `Blog` is removed from `gosite.yml` and its Cockpit models and entries are left in the database

#### Scenario: Legacy site
- **WHEN** the project has no `gosite.yml`
- **THEN** the addons commands keep their current file-copy behaviour

### Requirement: PHP addons come from the CMS image
The CMS image built for a thin site SHALL contain gosite's Cockpit addons at the same version as the site's core module, and the site's `cockpit/addons/` directory SHALL NOT hold copies of them.

#### Scenario: Core upgrade upgrades addons
- **WHEN** a site bumps the core version and rebuilds the CMS image
- **THEN** the Cockpit addons inside the image are the versions released with that core
