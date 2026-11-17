## ADDED Requirements

### Requirement: A site updates a submission through the Forms addon
The Forms addon SHALL provide `PATCH /api/forms/submissions/{id}`, which SHALL require an API token with `forms/manage`, SHALL sanitize the fields as a new submission's data is sanitized, SHALL merge them into the stored `data` and keep every field it does not receive, and SHALL NOT send e-mail or webhooks.

#### Scenario: Merge keeps other fields
- **WHEN** a submission has `data` `{email, domain, status: "en proceso"}` and the site sends `{status: "no iniciado"}`
- **THEN** the stored `data` is `{email, domain, status: "no iniciado"}` and no notification is sent

#### Scenario: Token without permission
- **WHEN** the request's API token does not have `forms/manage`
- **THEN** the addon answers 403 and the submission is unchanged

#### Scenario: Unknown submission
- **WHEN** the ID does not exist
- **THEN** the addon answers 404 and creates nothing

### Requirement: Forms have per-field options
`formSettings` SHALL have a `fieldOptions` field that maps a field name to a list of choices. The Forms addon SHALL provide `GET /api/forms/settings/{form}`, which SHALL require an API token and SHALL return only `label` and `fieldOptions`. Notification addresses, webhooks, secrets and limits SHALL NOT be in the answer.

#### Scenario: Site reads the choices
- **WHEN** `formSettings` for `diagnostico` has `fieldOptions` `{"mejorar": ["Ventas", "Marca"]}`
- **THEN** `GET /api/forms/settings/diagnostico` returns those choices and the form's label, and nothing else

#### Scenario: Form without settings
- **WHEN** a form has no `formSettings` entry
- **THEN** the endpoint answers 200 with an empty `fieldOptions`

### Requirement: Forms verify reCAPTCHA v3
When a form's `formSettings` sets `recaptchaMinScore`, the Forms addon SHALL verify the reCAPTCHA v3 token of every submit and of every `PATCH` that carries a token, using the CMS's `RECAPTCHA_SECRET_KEY`. It SHALL accept a token only when Google reports success, the token's action is in the form's `recaptchaActions`, and the score is at least `recaptchaMinScore`. A rejected or missing token SHALL be answered with 403 and `"error": "recaptcha"`. When Google cannot be reached or answers with something that cannot be read, the addon SHALL accept the request and log it.

#### Scenario: Low score
- **WHEN** a submit for a form with `recaptchaMinScore` 0.5 carries a token that Google scores 0.2
- **THEN** the addon answers 403 with `"error": "recaptcha"`, stores nothing and sends nothing

#### Scenario: Google unreachable
- **WHEN** the verify request to Google times out
- **THEN** the submission is stored as usual and the CMS log has a line saying that reCAPTCHA was not verified

#### Scenario: Form without reCAPTCHA
- **WHEN** a form's `formSettings` has no `recaptchaMinScore`
- **THEN** submits without a token are accepted as before this change

#### Scenario: Secret not configured
- **WHEN** a form sets `recaptchaMinScore` and `RECAPTCHA_SECRET_KEY` is empty
- **THEN** the addon accepts the request and logs that reCAPTCHA is enabled for the form but has no secret
