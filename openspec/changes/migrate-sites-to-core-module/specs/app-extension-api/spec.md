## ADDED Requirements

### Requirement: Sites register their own template functions
The core SHALL provide the option `gosite.WithFuncs(template.FuncMap)`, and the functions it passes SHALL be available in every theme template. `gosite.Run` SHALL return an error before it listens when a name in that map is already a core template function.

#### Scenario: Theme uses a site function
- **WHEN** a site passes `WithFuncs(template.FuncMap{"year": ...})` and a theme template calls `{{ year }}`
- **THEN** the page renders with the function's result

#### Scenario: Name collision
- **WHEN** a site passes a function named `safeHTML`
- **THEN** `gosite.Run` returns an error that names `safeHTML` and does not accept connections

### Requirement: CMS client covers the Forms addon
The core CMS client SHALL provide `Submit` (create a submission, optionally with a reCAPTCHA token and action), `UpdateSubmission` (merge fields into a submission's data, optionally with a reCAPTCHA token and action) and `FormSettings` (a form's public settings). Each SHALL call only the Forms addon's endpoints. A reCAPTCHA rejection SHALL be returned as an error that `errors.Is` matches with `cms.ErrRecaptcha`.

#### Scenario: Submission rejected by reCAPTCHA
- **WHEN** the Forms addon answers a submit with 403 and `"error": "recaptcha"`
- **THEN** `Submit` returns an error for which `errors.Is(err, cms.ErrRecaptcha)` is true

#### Scenario: Site updates a submission
- **WHEN** site code calls `UpdateSubmission(ctx, id, fields, nil)`
- **THEN** the request goes to `PATCH /api/forms/submissions/{id}`, not to the content API
