# Cockpit core — where models, memory and API keys live

Non-obvious behaviours discovered while wiring gosite scaffolds. Re-check after
Cockpit upgrades.

## Content model storage is configurable

Cockpit's `Content\Helper\Model` reads `content/models/storage` from the app
config (`$app->retrieve('content/models/storage')`, dotted into
`$config['content']['models']['storage']`).

- `'database'` → models saved to the data storage (`content/models` → MongoDB
  collection `content_models`) and **no** `storage/content/*.model.php` files.
- anything else (or unset) → models saved as files
  (`storage/content/<name>.model.php`), the core default.

The scaffold sets `'storage' => 'database'`. If you see a project with models
only in `storage/content/*.model.php` and nothing in Mongo `content_models`,
this config is missing (or set to `files`).

## Memory storage only supports Redis/redislite

`MemoryStorage\Client` (lib/MemoryStorage/Client.php) switches on the URI
scheme: `redislite://` (local sqlite) or anything else treated as **Redis**.
There is **no mongodb branch** — Cockpit core cannot put app memory in Mongo.

Default (no `memory` config): `redislite://<envDir>/storage/data/app.memory.sqlite`
→ creates a local sqlite file. The scaffold overrides it to the infra Redis
(DB 1, per-project `prefix`) via `memory` config; `COCKPIT_MEMORY_SERVER` env
wins when set.

Redis memory options used by the Client: `database` (select) and `prefix`
(Redis OPT_PREFIX). The URI path (e.g. `/1`) is **ignored** for DB selection —
use the `database` option.

## API keys live in the project database

Cockpit REST API keys are stored in the project's DB, collection
`system_api_keys` (dataStorage `system/api_keys`). Docs look like:

```json
{ "name": "...", "key": "<plaintext>", "role": "admin", "active": true }
```

Register one idempotently from the host with:

```bash
docker exec gosite-mongo mongosh "mongodb://127.0.0.1:27017/<project>" \
  --quiet --eval "db.system_api_keys.updateOne({key:'<tok>'},{\$setOnInsert:{name:'gosite',key:'<tok>',role:'admin',active:true}},{upsert:true})"
```

The token must be a registered key (with a role granting
`content/:models/manage` for model-management writes via the Webapp addon's
`/api/models/save`) or the REST API returns 403.

## FrankenPHP warmup vs the REST API

On first boot the CMS answers HTTP (root → 302) well before the REST routes are
wired, so readiness probes must hit an API endpoint (`/api/models` → 200/401/412
means ready), not the root. `gosite start`'s seed waits on the API and retries.
