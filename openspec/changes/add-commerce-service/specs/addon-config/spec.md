## ADDED Requirements

### Requirement: Addons can bring services
An addon SHALL be able to add services to a thin site's generated compose files, and `gosite generate` SHALL include an addon's services only while the addon is listed in `gosite.yml`.

#### Scenario: Commerce added
- **WHEN** a user runs `gosite addons add Commerce my-site` and then `gosite generate`
- **THEN** the generated compose files of `my-site` contain the commerce services and the CLI names them in its output

#### Scenario: Commerce removed keeps data
- **WHEN** a user removes `Commerce` from `gosite.yml` and runs `gosite generate`
- **THEN** the commerce services are no longer in the generated compose files and their volumes are not deleted

#### Scenario: Addon without services
- **WHEN** a site lists only addons that bring no services
- **THEN** the generated compose files are identical to those of the previous release

### Requirement: Commerce is a library addon
`Commerce` SHALL be part of gosite's addon library, so `gosite addons list` shows it and `gosite.yml` may list it.

#### Scenario: Listed in library
- **WHEN** a user runs `gosite addons list my-site`
- **THEN** `Commerce` appears among the available addons
