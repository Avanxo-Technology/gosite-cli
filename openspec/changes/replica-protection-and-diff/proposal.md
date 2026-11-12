## Why

Replica pushes whole content models, and its dry run only says "would create" or "would update" — it cannot show what differs between two instances. Some models hold content that is specific to one environment (for example per-page SEO overrides, or records that are created in production), and nothing stops a push from a local instance from overwriting them.

## What Changes

- Each instance can mark content models as **protected**. A protected model refuses every write that arrives through replication, whoever sends it. No model is protected by default; each project decides.
- The protected list is edited on the instance itself, in the Replica admin screen. Every change to the list is recorded in the activity log.
- The peer manifest advertises the protected models, so a source instance knows about them before it writes.
- A push to a protected model skips that model, counts it as `protected` (not as an error), logs it, and continues with the other models.
- A pull into a protected local model is refused the same way. Reading from a protected model is not restricted.
- A source warns when the destination runs a Replica version without protection support.
- New read-only **diff**: `replica:diff <target> [model]` and a Compare view in the admin screen. Each entry gets one of five states: only here, newer here, newer there, only there, same.
- `replica:push` accepts `--ids=a,b,c` to send specific entries, and the Compare view can push the entries the user selects.
- The dry-run plan reports identical entries as `same` instead of `would update`.

## Capabilities

### New Capabilities
- `replica-model-protection`: per-instance list of content models that refuse writes from replication, its admin screen, manifest advertisement and how push and pull react to it.
- `replica-diff`: read-only comparison of local and remote entries per model, and pushing a selected subset of entries.

### Modified Capabilities
<!-- None: Replica has no spec in openspec/specs/ yet. -->

## Impact

- Code: `src/addons/Replica/` — `api.php` (manifest, items and models endpoints), `Helper/Replica.php` (protection store, push/pull, diff, plan), `Helper/Client.php` (423 handling, manifest read), `Controller/Api.php` (protected list and diff endpoints), `views/index.php` (Protected and Compare views), new `Command/Diff.php`, `Command/Push.php` (`--ids`), `cli.php`, `README.md`.
- Peer API: new response `423 Locked` from `POST /api/replica/items/{model}` and `POST /api/replica/models`; new `protected` key in `GET /api/replica/manifest`. Older sources that receive 423 fail the run loudly instead of writing.
- Storage: new dataStorage collection `replica/protected` on each instance (not content, so replication cannot overwrite it).
- Delivery: the addon is baked into the CMS image, so sites need a CMS rebuild. Both instances need the new version for protection to take effect.
- Release: `Replica::VERSION` and `src/VERSION` bump.
