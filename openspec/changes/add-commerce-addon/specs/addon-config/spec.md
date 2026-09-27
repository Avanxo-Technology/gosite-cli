## ADDED Requirements

### Requirement: Addons read their own configuration
An addon's Go half SHALL receive the site's parsed `gosite.yml` at startup before its routes are mounted, SHALL read only keys prefixed with its lowercase name and an underscore, and startup SHALL fail when the addon rejects a value.

#### Scenario: Valid keys
- **WHEN** `gosite.yml` lists `Commerce` and sets `commerce_plp_path: /shop`
- **THEN** the commerce addon mounts the PLP at `/shop`

#### Scenario: Invalid value
- **WHEN** `gosite.yml` sets `commerce_region: xx`
- **THEN** startup fails with an error naming `commerce_region` and the accepted values

#### Scenario: Addon without configuration
- **WHEN** an addon defines no configuration hook
- **THEN** it starts exactly as before
