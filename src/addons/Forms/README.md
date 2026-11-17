# Forms — Inbox-style form manager for Cockpit v2

Receives form posts from a landing page, stores them as regular **Content
collections**, and adds a per-form admin screen with CSV export, plus e-mail and
webhook notifications.

Built and verified against `cockpithq/cockpit:core-2.14.0` (PHP 8.4, FrankenPHP).
No Composer dependencies, no CDN assets.

## Why collections

Submissions are ordinary content, so they show up in **Content** like anything
else and the standard content API works on them. The addon only adds what the
core does not have: a public receiver, anti-spam, per-form columns, CSV and
notifications.

Two collections are created **automatically** on first use — no manual setup:

| Collection | Fields |
| --- | --- |
| `formSubmissions` | `form`, `data` (object), `origin`, `ip`, `userAgent`, `read` |
| `formSettings` | `form`, `label`, `notify`, `subject`, `webhook`, `webhookFormat`, `webhookSecret`, `throttle`, `dailyLimit` |

`data` is an **object** field, so the landing page can add or rename fields
without ever touching the CMS. The admin screen derives one real column per
field from the submissions themselves.

## Layout

```
addons/Forms/
├── bootstrap.php          helper + route bindings
├── admin.php              sidebar menu, permission, model install
├── api.php                token REST surface under /api/forms/...
├── Controller/
│   ├── Api.php            /forms/api/{submit,list,forms,export,remove,read}
│   └── Admin.php          /forms admin screen
├── Helper/Forms.php       all business logic
├── views/index.php        per-form screen (vanilla JS)
└── assets/icons/forms.svg
```

> **The folder must be named `Forms`, with a capital F.** Lime's autoloader maps
> the namespace straight onto the directory name (`addons/` + `Forms/Helper/Forms.php`).
> A lowercase `forms/` works on macOS but **fatals on Linux**, which is where
> production runs. Core modules (`App`, `Content`, `System`) are capitalized for
> the same reason.

## Install

1. Copy `Forms` into your project's `addons/` folder and mount it:

   ```yaml
   services:
     cms:
       image: cockpithq/cockpit:core-2.14.0
       volumes:
         - ./addons:/var/www/html/addons     # add :ro in production
         # ...your existing mounts
   ```

2. **Clear the module cache.** In non-debug mode the module list is cached and
   the addon simply will not load until you remove it:

   ```bash
   rm -f cockpit-storage/cache/modules.cache.php   # host path of storage/cache
   docker compose restart cms
   ```

   A restart is needed anyway: FrankenPHP keeps the compiled bootstrap in
   opcache, so editing addon PHP without restarting shows stale code.

3. Grant the permission: **Settings → Roles →** *(your role)* → **`forms/manage`**.
   Admin users have it implicitly.

4. Open `/forms`. The collections are created the moment the screen loads or the
   first submission arrives.

## Endpoints

| Method | Route | Auth |
| --- | --- | --- |
| `POST` | `/forms/api/submit` | none (public receiver) |
| `GET` | `/forms/api/list?form=&page=&limit=` | `forms/manage` |
| `GET` | `/forms/api/forms` | `forms/manage` |
| `GET` | `/forms/api/export?form=` | `forms/manage` |
| `POST` | `/forms/api/remove/{id}` | `forms/manage` + CSRF |
| `POST` | `/forms/api/read/{id}?read=0\|1` | `forms/manage` + CSRF |

Token-authenticated (API key), for the site and for tools:

| Method | Route | Auth | |
| --- | --- | --- | --- |
| `GET` | `/api/forms/submissions?form=&page=&limit=` | `forms/manage` | list |
| `PATCH` | `/api/forms/submissions/{id}` | `forms/manage` | merge fields into a submission's data (below) |
| `DELETE` | `/api/forms/submissions/{id}` | `forms/manage` | remove |
| `GET` | `/api/forms/settings/{form}` | any API key | the form's `label` and `fieldOptions`, nothing else |
| `GET` | `/api/forms/export?form=` | `forms/manage` | CSV |

A site changes submissions only through these endpoints, never through the
content API: they sanitize, check `forms/manage`, and send notifications only
once, on submit. gosite's Go core calls them through `cms.Client` (`Submit`,
`UpdateSubmission`, `FormSettings`).

### Updating a submission

```http
PATCH /api/forms/submissions/{id}
{"data": {"status": "completo"}, "recaptcha": {"token": "…", "action": "lead"}}
```

The fields are sanitized like a new submission's and merged into the stored
`data`; fields not sent are kept. No e-mail and no webhook is sent. `recaptcha`
is optional: when it is given and the form sets `recaptchaMinScore`, the token
is verified as on submit (403 `{"error":"recaptcha"}` when it fails). Answers:
`200 {"success":true,"_id":…}`, `400` without data, `404` for an unknown ID.
For a form completed in steps, keep the `_id` the submit returned.

### Choices of a form's fields

`formSettings.fieldOptions` maps a field name to its choices, for example
`{"necesidad": ["Ventas", "Marca"]}`. The site reads them with
`GET /api/forms/settings/{form}` and renders the select; editors change them in
Content > Form settings. Empty choices and surrounding spaces are dropped.

CSRF uses the panel's own `App.csrf` global and the `X-CSRF-TOKEN` header,
validated against the `app.csrf` key — the same check core controllers perform.

### Submit payload

```json
{
  "form": "cotizar",
  "data": { "nombre": "Ana", "tel": "555-0100", "equipo": "Excavadora", "mensaje": "…" }
}
```

A flat body (`{"form":"cotizar","nombre":"Ana",...}`) and a classic
`application/x-www-form-urlencoded` POST are both accepted too.

A reCAPTCHA v3 token travels as `"recaptcha": {"token": "…", "action": "…"}` in
a JSON body, or as the fields `g-recaptcha-response` and `recaptcha_action` of a
form post. It is never stored with the data.

Responses: `200 {"success":true,"_id":"…"}` (the `_id` is absent when the
honeypot was filled), `400`/`429 {"success":false,"error":"…"}`,
`403 {"success":false,"error":"recaptcha"}`, or `503` with a `Retry-After`
header when the rate limiter's memory backend (Redis) is unreachable.

## Anti-spam

- **Honeypot** — a hidden field named `_hp`. If it arrives non-empty the
  submission is dropped silently and `{"success":true}` is still returned, so
  the bot never learns it was caught.
- **Throttle** — minimum seconds between submissions from the same IP+form
  (default `3`), in `$app->memory` (Redis).
- **Daily cap** — max submissions per IP+form per day (default `50`).
- **Client identity** — see *Behind a reverse proxy* below: the rate-limit
  bucket key is derived with proxy awareness, so two different visitors never
  share one bucket.

### reCAPTCHA v3

A form verifies reCAPTCHA when its `formSettings` sets `recaptchaMinScore`
(0–1). The secret is `forms.recaptchaSecret`, which gosite's config reads from
`RECAPTCHA_SECRET_KEY` on the CMS service; it never lives in a Cockpit entry.
`recaptchaActions` lists the actions the form's pages ask Google for.

| Request | Answer |
| --- | --- |
| no token | 403 `{"error":"recaptcha"}` |
| Google says it failed, the action is not in `recaptchaActions`, or the score is below `recaptchaMinScore` | 403 `{"error":"recaptcha"}` |
| Google cannot be reached (5-second timeout) or answers something unreadable | accepted; the log says `recaptcha: verify unreachable` |
| no `recaptchaSecret` configured | accepted; the log says the form asks for it |
| a form without `recaptchaMinScore` | accepted, as before |

The check runs before the rate limit counts the request. Every result is a
`[forms] recaptcha:` log line with the score, because Google's console lags by
hours. `forms.recaptchaVerifyUrl` replaces Google's verify URL; it exists for
tests and is never needed in production.

When a site posts to the addon from its server, every submission comes from the
site's address: the per-IP throttle and daily cap then count all visitors
together. Such a site keeps its own per-visitor limit.

### Fail-closed rate limiting

If the memory backend (Redis) is unreachable, submissions are rejected with
**HTTP 503** and a `Retry-After` header rather than accepted without a limit.
A Redis outage must not open an unlimited submission path exactly while the
system is degraded. To prefer availability deliberately, set both `throttle`
and `dailyLimit` to `0` for the form — the memory backend is then not consulted
at all.

### Behind a reverse proxy

The client IP used by the rate limiter comes from
the `forms.trustedProxies` key of `cockpit/config.php`, an **integer**
counting how many reverse-proxy hops sit in front of the CMS (default `0`).
With `N` trusted hops, the identity is taken N entries from the **right** of
`X-Forwarded-For`; anything further left could have been invented by the
client itself and is discarded. If the header carries fewer entries than
configured hops, it falls back to `REMOTE_ADDR`.

Every gosite scaffold ships `'trustedProxies' => 1` in its generated
`cockpit/config.php`, because every gosite site sits behind exactly one Traefik
hop. Direct connections keep `trustedProxies` at `0`.

The legacy boolean `'trustProxy' => true` still works and behaves as
`trustedProxies => 1`, but logs a deprecation notice — migrate to the integer.

### Landing page snippet

```html
<form id="quote">
  <input name="nombre" required>
  <input name="tel" required>
  <input name="equipo">
  <textarea name="mensaje"></textarea>
  <!-- honeypot: keep it off-screen, not display:none -->
  <input name="_hp" tabindex="-1" autocomplete="off"
         style="position:absolute;left:-9999px" aria-hidden="true">
  <button>Enviar</button>
</form>

<script>
document.getElementById('quote').addEventListener('submit', async (e) => {
  e.preventDefault();
  const data = Object.fromEntries(new FormData(e.target));
  const hp = data._hp; delete data._hp;
  const res = await fetch('https://cms.example.com/forms/api/submit', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ form: 'cotizar', data, _hp: hp })
  });
  const out = await res.json();
  alert(out.success ? '¡Gracias!' : out.error);
});
</script>
```

## Notifications

Create one item in **Content → Form settings** per form:

| Field | Meaning |
| --- | --- |
| `form` | must match the `form` value the landing sends, e.g. `cotizar` |
| `label` | name shown in the Forms screen |
| `notify` | e-mails that receive a summary of every submission |
| `subject` | e-mail subject (defaults to `New submission: <form>`) |
| `webhook` | URL that receives a POST per submission |
| `webhookFormat` | `json` (default), `mattermost`, or `none` to opt this form out |
| `webhookSecret` | signs the body as `X-Forms-Signature: sha256=<hmac>` |
| `throttle` | seconds between submissions per IP (`0` disables) |
| `dailyLimit` | max per IP per day (`0` disables) |

### The webhook default, and why the format is a field

The CMS config carries a default for every form, read from the environment
(`cockpit/config.php` in legacy sites, `cockpit/config.core.php` in thin ones):

```php
'forms' => [
    'webhook'       => getenv('FORMS_WEBHOOK_URL') ?: null,
    'webhookFormat' => getenv('FORMS_WEBHOOK_FORMAT') ?: 'json',
    'webhookSecret' => getenv('FORMS_WEBHOOK_SECRET') ?: null,
],
```

A form's own field wins when it is set, so the environment default is what makes
the setting hold for a form **nobody has configured yet** - create a form in the
CMS and it inherits the webhook with no per-form setup. Leave the variables
unset to configure each form in **Content → Form settings** instead.

Because of that default, a form opts OUT with `webhookFormat: none`, not by
clearing the URL: an empty text field arrives as `null`, which is
indistinguishable from a field nobody has filled in yet.

`webhookFormat` exists because a receiver does not get to choose the shape this
addon sends, and a mismatch is **silent**: the POST goes out, the receiver
answers 4xx, and the only trace is one line in this addon's log - the submission
is stored either way.

| Format | Body |
| --- | --- |
| `json` | the flat object shown below - the original contract |
| `mattermost` | `{"text": …, "attachments": […]}` for an incoming webhook |

Mattermost (and Slack) reject the flat object with `400 "Failed to handle the
payload …"`, because both require `text` or `attachments`. The `mattermost`
format sends the submitted fields as one attachment field per field, and
**only** those fields - no IP and no user agent, since the chat is a second
system that does not inherit this addon's `personal_data_retention`.

The message wording comes from the site's `forms` config (`cockpit/config.php`
in legacy sites, `cockpit/config.local.php` in thin ones). All three keys are
optional and are the same in every environment:

| Key | Effect | Unset |
| --- | --- | --- |
| `webhookHeading` | message text; `{form}` becomes the form's label | `New **{form}** submission` |
| `webhookSiteName` | shown before the date in the footer | the date only |
| `webhookColor` | colour of the attachment bar, e.g. `#0055AA` | Mattermost's neutral colour |

E-mail goes through `$app->mailer`. Sites scaffolded by gosite 0.55.0 or later
configure it from the CMS environment: set `SMTP_HOST` (plus `SMTP_PORT`,
`SMTP_ENCRYPTION`, `SMTP_USER`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_FROM_NAME`)
in `.env` or in Coolify. Without `SMTP_HOST` Cockpit falls back to PHP `mail()`,
which the CMS image cannot deliver, so `notify` only logs `mail failed`.

The `json` format's webhook payload:

```json
{
  "event": "submission.created",
  "form": "cotizar",
  "data": { "nombre": "…", "tel": "…" },
  "origin": "https://lnequipos.co",
  "ip": "190.0.0.1",
  "userAgent": "…",
  "_id": "6a721c46…",
  "_created": 1785863238
}
```

Verify the signature on your side with
`hash_hmac('sha256', $rawBody, $secret)`.

Both are best-effort and fire **after** the submission is stored: a dead SMTP
server or a 500 from your webhook is logged, never a lost lead. The webhook call
is synchronous with a 5s timeout, so a slow endpoint delays the response by at
most that much.

## Global configuration — `config/config.php`

```php
'forms' => [
    // Origins allowed to post from another origin (CORS). When unset, NO
    // Access-Control-Allow-Origin header is emitted: browsers block
    // cross-origin posts, and same-origin forms keep working. Explicitly opt
    // into openness with ['*'] if you really mean it.
    'allowed_origins' => ['https://www.example.com'],
    // Number of trusted reverse-proxy hops in front of the CMS (see above).
    'trustedProxies' => 1,
    // reCAPTCHA v3 secret, for forms that set recaptchaMinScore.
    'recaptchaSecret' => getenv('RECAPTCHA_SECRET_KEY') ?: null,
],
```

## Smoke test

```bash
docker compose up -d
rm -f cockpit-storage/cache/modules.cache.php && docker compose restart cms

# public submit
curl -s -X POST http://localhost:8001/forms/api/submit \
  -H 'Content-Type: application/json' \
  -d '{"form":"cotizar","data":{"nombre":"Ana","tel":"555-0100","equipo":"Excavadora"}}'
# -> {"success":true,"_id":"…"}

# throttle: repeat immediately -> HTTP 429
# honeypot: add "_hp":"bot" -> {"success":true} but no row stored

# verify storage
docker exec <cms> php -r '
  require "/var/www/html/bootstrap.php";
  $app = Cockpit::instance("/var/www/html");
  print_r($app->module("content")->items("formSubmissions"));
'
```

Then log into the panel: **Forms** in the sidebar lists each form separately
with its own columns and Export CSV; the same items appear under
**Content → Form submissions**.
