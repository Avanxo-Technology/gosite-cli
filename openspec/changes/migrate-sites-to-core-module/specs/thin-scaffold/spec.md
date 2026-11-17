## ADDED Requirements

### Requirement: Thin sites can own Cockpit addons
A thin site SHALL be able to keep its own Cockpit addons in `cockpit/site-addons/<Name>/`. When that folder has at least one addon, the generated `deploy/Dockerfile.cms` SHALL copy it into the CMS image next to gosite's addons. `gosite generate` SHALL NOT write, move or delete anything in that folder, and SHALL refuse to run when a site addon has the name of a gosite addon.

#### Scenario: Site with its own addon
- **WHEN** a thin site has `cockpit/site-addons/Casos/bootstrap.php` and runs `gosite generate`
- **THEN** `deploy/Dockerfile.cms` copies `cockpit/site-addons/` into the image's addons folder, and the CMS loads `Casos` in local, QA and production builds

#### Scenario: Site without site addons
- **WHEN** a thin site has no `cockpit/site-addons/` folder, or the folder is empty
- **THEN** the generated `deploy/Dockerfile.cms` is byte-identical to the one before this change

#### Scenario: Name collision with a gosite addon
- **WHEN** a site has `cockpit/site-addons/Forms/`
- **THEN** `gosite generate` changes no file, names the folder and the gosite addon it collides with, and exits non-zero

#### Scenario: Disabled gosite addons do not affect site addons
- **WHEN** `gosite.yml` lists no gosite addons
- **THEN** `modules.disabled` in `config.core.php` names only gosite addons, and every site addon stays enabled

### Requirement: reCAPTCHA secret reaches the CMS
The generated composes SHALL pass `RECAPTCHA_SECRET_KEY` to the CMS service as an optional variable (empty when unset) in local, QA and production, and SHALL NOT pass it to the app service.

#### Scenario: Secret set in production
- **WHEN** `RECAPTCHA_SECRET_KEY` is set in the production environment
- **THEN** the CMS container sees it and the app container does not
