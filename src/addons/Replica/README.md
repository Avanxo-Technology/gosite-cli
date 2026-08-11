# Replica — content replication for Cockpit v2

Replicate collections, singletons, model/schema definitions and assets between
Cockpit instances: push, pull, multiple targets, mirror/merge conflict handling,
dry runs, an activity log, an admin screen and a CLI.

Built and verified against `cockpithq/cockpit:core-2.14.0` (PHP 8.4, FrankenPHP).
No Composer dependencies.

> **Independent project.** This addon is not affiliated with, endorsed by, or
> derived from Cockpit Pro or any commercial Cockpit addon. It was written from
> scratch against the open-source core and is released under the MIT license
> (see `LICENSE`). "Cockpit" is the name of the upstream CMS and is used here
> only to describe compatibility. Repository name:
> **cockpit-content-replica-addon**.

---

## How it works, and what the core can and cannot do

Two transports, chosen automatically by probing the remote:

### `peer` — Replica installed on both instances (recommended)

Full fidelity. The addon exposes its own REST endpoints, so it can transfer:

- **model/schema definitions** — the core has *no* REST endpoint for models, so
  this is only possible peer-to-peer;
- **entries with `_id`, `_created` and `_modified` preserved exactly**;
- **assets** — the metadata of every asset registered in the source instance
  (the `assets` dataStorage collection and its folders), plus the original file
  bytes, so embedded media references keep resolving (see
  [Asset replication](#asset-replication)).

### `core` — plain Cockpit on the far side

Only `/api/content/*` exists, and it is lossy. Verified behaviour of
`POST /api/content/item/{model}`:

| Payload | Result |
| --- | --- |
| no `_id` | creates the entry, assigning **its own** `_id` |
| existing `_id` | updates correctly |
| non-existent `_id` | returns **HTTP 200 and echoes the document, but writes nothing** |

That last row is a real trap: naively pushing entries with their source `_id`
reports success while silently discarding every new entry. Replica therefore
indexes the remote first and omits `_id` when creating — and then **remembers
the id the remote minted**, in `replica/idmap`, keyed by target and collection.

That mapping is what makes `core` mode repeatable rather than one-shot:

- the next push finds the mapping and *updates* the right entry instead of
  creating a second copy, so running push twice is idempotent;
- a pull translates the remote ids back to ours, so a push-then-pull round trip
  does not duplicate everything locally;
- a mapping is dropped automatically once its remote entry provably disappears,
  and `--reset-map` forces a clean re-seed.

Remaining `core` limitations, which no client can work around:

- `_created`/`_modified` are stamped by the remote at write time, because the
  core strips every key outside `_id`, `_state` and the declared model fields;
- **every core read endpoint hard-codes `filter._state = 1`**, so unpublished
  remote entries are invisible. Replica cannot tell "unpublished" from "deleted"
  and trusts the mapping, marking such writes `[unverified]` in the log;
- model definitions cannot be transferred at all.

Use `core` mode for a plain instance. Use `peer` mode when you want two
instances genuinely in lockstep, including unpublished entries.

---

## Layout

```
addons/Replica/
├── bootstrap.php        helpers, route bindings, event hooks
├── admin.php            menu, permission, admin screen route
├── api.php              peer REST endpoints (/api/replica/*)
├── cli.php              Symfony Console command registration
├── Command/             replica:* CLI commands
├── Controller/
│   ├── Admin.php        /replica screen
│   └── Api.php          /replica/api/* (session auth + CSRF)
├── Helper/
│   ├── Replica.php      targets, operations, log
│   └── Client.php       remote HTTP client + transport detection
├── Model/Target.php     target value object; the only place the key is read
├── views/index.php
├── assets/icons/replica.svg
├── LICENSE              MIT
└── README.md
```

> **The folder must be named `Replica`, with a capital R.** Lime's autoloader
> maps the namespace straight onto the directory name, so a lowercase folder
> works on macOS and **fatals on Linux**.

---

## Install

1. Copy `Replica` into the project's `addons/` folder and mount it:

   ```yaml
   services:
     cms:
       image: cockpithq/cockpit:core-2.14.0
       volumes:
         - ./addons:/var/www/html/addons     # add :ro in production
   ```

2. **Delete the module cache** — in non-debug mode the module list is cached and
   the addon will not load until you remove it:

   ```bash
   rm -f cockpit-storage/cache/modules.cache.php   # host path of storage/cache
   docker compose restart cms
   ```

   The restart is required anyway: FrankenPHP keeps the compiled bootstrap in
   opcache, so edited addon PHP silently runs stale.

3. Grant **Settings → Roles → `replica/manage`**. Admins have it implicitly.

4. On **each remote instance** you want to replicate with, install the addon the
   same way and create an API key under **Settings → API & Security** whose role
   holds `replica/manage`. That key goes into the target configuration on the
   source.

---

## Configuring a target

Admin screen (**Replica** in the sidebar) or CLI:

```bash
docker compose exec cms php /var/www/html/tower \
  replica:targets:add staging https://cms.staging.example.com <API_KEY> \
  --models=posts,pages --sync-models --sync-assets
```

| Field | Meaning |
| --- | --- |
| `name` | label used by the CLI and the log |
| `base_url` | root URL of the remote instance |
| `api_key` | key issued by the **remote**; stored server-side, always masked in the UI and API |
| `models` | content models in scope (collections and singletons); empty means *all* |
| `syncModels` | also replicate model/schema definitions (peer only) |
| `syncAssets` | also replicate assets — metadata + original files (peer only) |
| `enabled` | disabled targets keep their settings but refuse to run |

The API key is never sent back to the browser: `Target` exposes it only through
`apiKey()`, which the HTTP client alone calls, while `toArray()`/`jsonSerialize()`
mask it. Leaving the field empty when editing keeps the stored key.

---

## Running

### Admin screen

A collapsible **How mode and dry run work** panel explains the two knobs in
place, and every control carries a tooltip.

The target editor groups **Content models** into Collections and Singletons with
a live "N of M selected" counter, a filter box, and Select all / Clear buttons —
none selected means every content model. A separate **Also replicate** group
turns model definitions and assets on and off.

Per target: an **Active/Inactive** switch, a mode selector, a dry-run checkbox,
**Push now**, **Pull now**, **Test** (reachability + transport), edit and delete.
Push and Pull are disabled while a target is inactive. Results are shown per
run, and the activity table lists every operation.

### CLI

```bash
tower replica:targets:list [--ping]
tower replica:targets:add <name> <base_url> <api_key> [--models=a,b] [--sync-models] [--sync-assets] [--disabled]
tower replica:targets:toggle <target> [--on|--off]     # no flag flips the state
tower replica:targets:sync <target>    # fold every local content model into the scope
tower replica:targets:remove <target>

tower replica:push <target> [model] [--mode=merge|mirror] [--dry-run] [-v] [--reset-map] [--assets]
tower replica:pull <target> [model] [--mode=merge|mirror] [--dry-run] [-v] [--assets]

tower replica:log [--target=<name>] [--limit=20]
```

`<target>` accepts the name or the id — target names are unique, so it is never
ambiguous. `-v` is Symfony Console's own verbosity flag and logs every entry
rather than errors only. `--reset-map` forgets the remembered remote ids for a
core target, re-seeding it from scratch. `--assets` forces asset replication on
a single run even when the target has them excluded.

When a target carries an explicit `models` list that misses a local content
model, every push/pull prints
`Not in target scope: <names> (run replica:targets:sync "<target>" to include them)`
so newly added models cannot silently fall out of replication again.

### Active / inactive

Deactivating a target keeps its URL, key and scope but makes every run refuse to
start — the safe way to pause replication to an instance that is down or
mid-deploy, without losing its configuration. Toggle it from the switch on the
target card or with `replica:targets:toggle`.

### Modes

- **`mirror`** — the source always wins, overwriting the destination.
- **`merge`** — the newest `_modified` wins. When the destination is newer the
  entry is skipped and recorded as `skip <id>: destination is newer`.

Existing entries are replaced, not merged field-by-field, so a field deleted at
the source is also gone at the destination.

### Dry run

`--dry-run` reports exactly what would change — including the remote lookups
needed to classify each entry — and writes nothing on either side. It is still
recorded in the log, flagged `[dry]`.

---

## Asset replication

Turning **Replicate assets** on for a target (or passing `--assets` on a run)
also copies the media the source instance has registered in Cockpit — the
`assets` metadata collection, its folders, and the original file bytes. Both
directions are supported and **peer only**: the core exposes no asset write
endpoint, so a plain Cockpit remote logs `Assets skipped: requires Replica on
the remote.` (same as model definitions).

How it works:

- files travel as base64 `fileData` inside the asset payload, so metadata and
  bytes move in one request per asset;
- `_id`, `path`, `_created` and `_modified` are preserved, so references inside
  the replicated entries resolve to real local files;
- `_modified` on the metadata obeys the same mirror/merge rules as entries: in
  merge mode a destination asset that is newer is skipped;
- asset metadata lives in the source's `assets` dataStorage collection (a
  table MongoLite creates on first write), so a fresh instance that never
  uploaded anything has no assets to copy — the run just reports
  `assets: nothing to send`.

The activity log gains an `assets` summary (created/updated/skipped/errors)
alongside the per-collection counts, and `replica:targets:list` shows whether a
target has assets included.

## Id map

`replica/idmap` holds `sourceId → remoteId` pairs per target and collection. It
only ever fills for `core` targets — a peer keeps our ids verbatim, so nothing
needs remembering. `replica:targets:list` reports how many pairs a target has,
removing a target purges its pairs, and `replica:push --reset-map` clears them.

## Activity log

Every operation appends to `replica/log`: timestamp, direction, target, mode,
dry-run flag, transport, per-collection created/updated/skipped/error counts and
messages (truncated at 500 lines). Read it with `replica:log`, in the admin
screen, or over the admin API at `GET /replica/api/log`.

---

## Endpoints

Admin API (session + `replica/manage`, CSRF on mutations):

| Method | Route |
| --- | --- |
| `GET` | `/replica/api/targets` |
| `POST` | `/replica/api/target` |
| `POST` | `/replica/api/toggle/{id}` |
| `POST` | `/replica/api/remove/{id}` |
| `GET` | `/replica/api/ping/{id}` |
| `POST` | `/replica/api/run/{id}` |
| `GET` | `/replica/api/log` |

Peer API (api-key + `replica/manage`), consumed by the other instance:

| Method | Route |
| --- | --- |
| `GET` | `/api/replica/manifest` |
| `GET` `POST` | `/api/replica/models` |
| `GET` `POST` | `/api/replica/items/{model}` |
| `GET` `POST` | `/api/replica/assets` |
| `GET` | `/api/replica/assets/file/{id}` |

---

## Verification

Reproduces the end-to-end test this addon was validated with: instance **A** is
your stack, **B** a peer, **C** a plain Cockpit without the addon.

```bash
# B — a peer (mount the same addons folder)
docker run -d --name replica-b --network <net> -p 8002:80 \
  -v replica-b-storage:/var/www/html/storage \
  -v $PWD/addons:/var/www/html/addons \
  cockpithq/cockpit:core-2.14.0

# an API key on B
docker exec replica-b php -r '
require "/var/www/html/bootstrap.php"; $a = Cockpit::instance("/var/www/html");
$k = ["key"=>"rep-b-".bin2hex(random_bytes(8)),"name"=>"peer","role"=>"admin",
      "meta"=>[],"_created"=>time(),"_modified"=>time()];
$a->dataStorage->insert("system/api_keys", $k); echo $k["key"]."\n";'

# the peer endpoints answer only with a valid key
curl -s http://localhost:8002/api/replica/manifest             # {"error":"Authentication failed"}
curl -s -H "api-key: <KEY>" http://localhost:8002/api/replica/manifest
# {"replica":"1.0.0","cockpit":"2.14.0","models":[...]}

# A — register B and replicate
tower replica:targets:add staging-b http://replica-b:80 <KEY> --models=<coll> --sync-models
tower replica:push staging-b --dry-run -v      # plan only
tower replica:push staging-b                   # model + entries
```

Checks worth making afterwards:

```bash
# identical _id / _created / _modified on both sides
docker exec <a> php -r 'require "/var/www/html/bootstrap.php"; $a=Cockpit::instance("/var/www/html");
foreach ($a->dataStorage->find("content/collections/<coll>")->toArray() as $i)
  echo $i["_id"]." c=".$i["_created"]." m=".$i["_modified"]."\n";'
# ...same command against B

# merge: make one entry newer on B, then push from A -> that entry is skipped
tower replica:push staging-b --mode=merge -v
#   skip <id>: destination is newer

# mirror: the same push overwrites it
tower replica:push staging-b --mode=mirror -v

# pull: create an entry only on B, bring it back
tower replica:pull staging-b -v

# core fallback: a target on an instance WITHOUT the addon
tower replica:targets:add plain-c http://replica-c:80 <KEY_C> --models=<coll>
tower replica:push plain-c -v
#   transport=core
#   Model definitions skipped: requires Replica on the remote.
#   create <id> -> remote <other>, mapping remembered

# push again: idempotent thanks to the id map, no duplicates
tower replica:push plain-c
#   created 0, updated N   <- and the remote still holds N entries, not 2N

# pull back: ids are translated, nothing is duplicated locally
tower replica:pull plain-c -v

tower replica:log
```

An unreachable target fails fast and is logged as
`FAILED: Target unreachable at <url>: <reason>` with `transport=n/a`, rather than
being mistaken for a plain Cockpit.

In `core` mode the destination model must already exist — the core cannot
receive schema. Create it in the remote's Content UI first.

---

## License

MIT — see `LICENSE`.
