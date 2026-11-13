## Context

Replica (`src/addons/Replica/`, `Replica::VERSION = 1.0.0`) replicates content models between Cockpit instances. The smallest unit a user can choose is one model. Nothing is protected on the receiving side: any instance holding a key with `replica/manage` can overwrite any model.

Facts from the current code that shape this design:

- `Client::pushItems()` and `pushModels()` throw on any non-200 answer (`Helper/Client.php`). The throw is caught once around the whole `push()`, so one refused model aborts the run.
- `planRemote()` (`Helper/Replica.php`) reports every existing entry as `would update`, including identical ones, and never shows entries that exist only on the remote.
- No mode deletes entries on the destination that the source lacks; `mirror` only overwrites.
- The core transport strips `_created`/`_modified` and hides unpublished entries (`filter._state = 1`).

## Goals / Non-Goals

**Goals:**
- The destination decides what it accepts, whoever pushes.
- A user can see what differs before writing, and push only what they choose.
- Older clients against a newer destination fail loudly, never silently overwrite or silently do nothing.

**Non-Goals:**
- Source-side exclusion lists per target. Rejected by the user in favour of destination-side protection.
- Protecting assets. Assets are not per model; the per-target "Replicate assets" switch stays the control.
- Protection on a core destination. The client cannot enforce anything there; Cockpit role permissions on the API key are the tool.
- Deleting `only-there` entries from the diff. The diff and the selective push only create and update.
- A selective pull (`pull --ids`). See Open Questions.

## Decisions

### D1. The list lives in the destination's dataStorage, `replica/protected`
One document per protected model: `{ model, by, _created }`. It sits next to `replica/targets` and `replica/log`, outside `content/*`, so no replication path reads or writes it.

Alternatives: an environment variable (`REPLICA_PROTECTED_MODELS`) set in Coolify — harder to change by accident, but the user chose an editable view; a flag inside each model definition — rejected, because `syncModels` replicates definitions and would carry the flag across instances.

**Where the value comes from:** on each instance, from its own admin screen. Local and production hold independent lists; nothing is inherited.

### D2. Enforcement in the peer endpoints, through one helper
`Replica::isProtected(string $model): bool` and `protectedModels(): array`. `api.php` checks before `applyItems()` / `applyModels()` and answers **423 Locked** with `{ "error": "...", "protected": [...] }`. The pull loop calls the same helper before writing locally.

Why 423 and not 200 with a marker: a 1.0.0 client reads a 200 body into its counters and would report a run that wrote nothing as successful. A 423 hits the existing non-200 throw, so an old client fails the run with a visible message. Why not 403: 403 already means "the key lacks `replica/manage`", and the new client must tell the two apart.

A models POST that contains any protected model is refused as a whole. The new client never sends one (D3), so this only affects old clients, where refusing everything is the safe reading.

### D3. The source filters before it writes, and also handles 423
`push()` reads `protected` from the manifest it already fetches for transport detection, removes those models from the run, and adds them to a new `protected` counter. `pushItems()`/`pushModels()` turn a 423 into a `ProtectedModel` result instead of an exception, which covers protection added during a run. Other non-200 answers keep throwing.

### D4. Sameness is a content hash; direction is `_modified`
Hash = sha256 of the JSON of the entry after normalising: drop `_id`, `_created`, `_modified`, `_mby`, `_cby`; keep `_state` and the declared model fields only; sort keys recursively (lists keep their order). For a peer, a differing hash uses `_modified` to pick `newer-here`/`newer-there`. For a core target, timestamps are the remote's, so a difference is `newer-here` with a note.

Alternatives: compare `_modified` only — cheap, but a re-save without changes shows as different and a core target cannot be compared at all; compare field by field and show a field diff — useful later, but it is a UI feature on top of the same hash.

The dry-run plan reuses the same function, so `same` replaces a misleading `would update`.

### D5. Diff is a Helper method, shared by CLI and admin
`Replica::diff(Target, ?string $model): array` returns per model `{ protected, counts, entries: [{ id, remoteId, state, title }] }`. `title` is the first text field of the entry, so the admin list is readable without opening entries. `Command/Diff.php` prints counts, and with `-v` every non-`same` entry. The admin Compare view shows the five states as tabs per model, with checkboxes on `only-here` and `newer-here`.

### D6. Selective push reuses `push()`
`push()` gets an `ids` option. With `ids`, the model argument is required, `localItems()` results are filtered by `_id`, and unknown ids are reported. Mode, dry run, id map and protection apply unchanged.

## Risks / Trade-offs

- [An admin on the destination unprotects a model and nobody notices] → every change is in the activity log with the user; the Protected view shows who protected a model and when.
- [A source still on 1.0.0 pushes to a protected destination] → the run fails with HTTP 423 visible in the log; nothing is written. Upgrade the source.
- [A destination still on 1.0.0 has no protection] → the push prints `Destination Replica 1.0.0 does not support model protection` on every run.
- [Normalisation misses a field the remote rewrites, so equal entries show as different] → test with real entries of each addon model (Blog, Webapp, Forms, Analytics) on a peer and a core target; add the field to the drop list if needed.
- [A site that replicated "all models" stops sending a model once it is protected] → this is the intended change, and the result names the model on every run, so it is never silent.
- [Diff over large collections is slow] → it reads both sides once with the existing paginated `fetchItems()`; same cost as today's dry run.

## Migration Plan

1. Release a gosite version with Replica 1.1.0 and bump `src/VERSION`.
2. Rebuild the CMS image of each site that uses Replica. Upgrade the destination first. A 1.0.0 source against a 1.1.0 destination fails only on protected models; with an empty list nothing changes.
3. Mark protected models per environment in the admin screen.
4. Rollback: an older image ignores `replica/protected`; the list stays stored and applies again after a new upgrade.

## Open Questions

- Pull into a protected local model is refused here, by symmetry: protection is against any replication write into an instance. Confirm that this matches the intent.
- A protected model is skipped and the run continues (the user did not choose between this and failing the whole run). Confirm.
- Selective pull (`pull --ids`) for `newer-there` entries: useful from the Compare view, but out of scope until confirmed.
