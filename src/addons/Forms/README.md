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
| `formSettings` | `form`, `label`, `notify`, `subject`, `webhook`, `webhookSecret`, `throttle`, `dailyLimit` |

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

Token-authenticated equivalents: `GET /api/forms/submissions`,
`DELETE /api/forms/submissions/{id}`, `GET /api/forms/export`. The standard
content API (`/api/content/items/formSubmissions`) also works.

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

Responses: `200 {"success":true}`, `400`/`429 {"success":false,"error":"…"}`,
or `503` with a `Retry-After` header when the rate limiter's memory backend
(Redis) is unreachable.

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

### Fail-closed rate limiting

If the memory backend (Redis) is unreachable, submissions are rejected with
**HTTP 503** and a `Retry-After` header rather than accepted without a limit.
A Redis outage must not open an unlimited submission path exactly while the
system is degraded. To prefer availability deliberately, set both `throttle`
and `dailyLimit` to `0` for the form — the memory backend is then not consulted
at all.

### Behind a reverse proxy

The client IP used by the rate limiter comes from
`config/forms/trustedProxies`, an **integer** counting how many reverse-proxy
hops sit in front of the CMS (default `0`). With `N` trusted hops, the identity
is taken N entries from the **right** of `X-Forwarded-For`; anything further
left could have been invented by the client itself and is discarded. If the
header carries fewer entries than configured hops, it falls back to
`REMOTE_ADDR`.

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
| `webhook` | URL that receives a JSON POST per submission |
| `webhookSecret` | signs the body as `X-Forms-Signature: sha256=<hmac>` |
| `throttle` | seconds between submissions per IP (`0` disables) |
| `dailyLimit` | max per IP per day (`0` disables) |

E-mail goes through `$app->mailer` (your configured SMTP transport). Webhook
payload:

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
# -> {"success":true}

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
