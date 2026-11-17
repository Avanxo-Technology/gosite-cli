## ADDED Requirements

### Requirement: Generated files do not depend on the generating machine
Generated files SHALL NOT contain an absolute path of the machine that generated them; the local CMS build context for gosite's addons SHALL be `${GOSITE_ADDONS_DIR}`, which every compose command gosite runs SHALL export as the installed CLI's addons directory.

#### Scenario: Two machines generate the same file
- **WHEN** the same site at the same version is generated on two machines with gosite installed in different places
- **THEN** the local `docker-compose.yml` is byte-identical on both

#### Scenario: gosite start builds the CMS
- **WHEN** a user runs `gosite start <site>` on a thin site
- **THEN** the CMS image builds with the addons of the installed CLI

#### Scenario: docker compose without gosite
- **WHEN** a user runs `docker compose build cms` by hand without `GOSITE_ADDONS_DIR`
- **THEN** compose fails with a message that names `GOSITE_ADDONS_DIR` and how to set it
