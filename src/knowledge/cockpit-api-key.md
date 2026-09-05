# The Cockpit API key: two places, and only one of them is read

`COCKPIT_API_TOKEN` has to exist in **two** places before the application can
read the CMS, and the one everybody looks at is not the one that decides.

| Where | What it is | Who writes it |
| ----- | ---------- | ------------- |
| `system/api_keys` (Mongo: `system_api_keys`) | the durable record | the admin panel, or the Webapp addon |
| `app.api.keys` in app memory (**Redis**, DB 1, per-project prefix) | the registry the gate actually reads | `System\Helper\Api::cache()` |

`modules/App/api.php` gates every `/api/*` request on
`$this->helper('api')->getKey($token)`, and that helper reads the **memory
registry**, never the collection:

```php
$this->keys = $this->app['debug']
    ? $this->cache(false)
    : $this->app->memory->get('app.api.keys', fn() => $this->cache());
```

## The trap

`MemoryStorage\Client::get()` calls its default closure only when Redis returns
`false` — that is, when the key is **absent**. An empty registry is stored as
`a:0:{}`, which is a perfectly good value, so the closure never runs again.

So the first request that reaches the API helper before any key exists caches an
empty registry, permanently. And because our memory is Redis in shared infra,
that empty value outlives the CMS container: rebuilding the image, or recreating
the project's containers, does not clear it.

Two consequences that cost real debugging time:

- **Writing the key straight into Mongo does not work.** `gosite start` used to
  upsert with `mongosh`. The record appeared, `db.system_api_keys.find()` showed
  it, and every read still answered `412 {"error":"Authentication failed"}`,
  because nothing had invalidated the registry.
- **Checking only the collection does not work either.** `ensureApiKey()` used
  to `findOne()` and return early on a hit. That made the "in Mongo, absent from
  the registry" state self-perpetuating: opening the admin panel, the one thing
  that runs the check, confirmed the key was there and did nothing.

## The rule

Any code that adds, removes or repairs an API key must rewrite `app.api.keys`
in app memory in the same breath. `Webapp::rebuildApiRegistry()` is that code.

It deliberately does **not** call `System\Helper\Api::cache()`, even though that
is nominally the method for the job. Asking the app for the helper constructs
it, and `initialize()` snapshots the current — stale — registry into a private
array *before* `cache()` runs. The gate then queries that same instance and
still fails, so the repair only takes effect on the *next* request. Writing
memory directly leaves the helper unbuilt, so whoever constructs it later reads
the corrected value and the request that triggered the repair is already served
correctly. Verified both ways: via the helper, the first request after a wiped
registry answers 412; writing memory directly, it answers 200.

The registry shape must match what `Api::cache()` writes — the key string mapped
to the whole record, because the gate reads `$key['role']` off it.

## Where it runs

- `app.admin.init` — cheap, frequent, and where somebody would be looking.
- Lime's `before` event, filtered to `/api/*` — because the admin hook never
  fires on a deployed site nobody logs into, which is exactly the site whose
  reads are failing.

Do **not** repair this by binding `/api/*` in an addon. Lime's routes are a map
keyed by path (`App::bind` assigns, it does not append), so a second bind on
that path replaces the core's API gate outright and takes authentication with
it.

## While debugging

`opcache.validate_timestamps` is **Off** in the CMS image, so editing a PHP file
in a running container changes nothing until the container restarts. A
`docker cp` that appears to have no effect has simply not been loaded yet.
