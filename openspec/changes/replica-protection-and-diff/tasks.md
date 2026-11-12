## 1. Sandbox baseline

- [ ] 1.1 Start two peer CMS containers and one plain Cockpit for the sandbox site `~/gosites/analytics-draft-v2` (README "Verification" pattern, own Docker network, no real infra)
- [ ] 1.2 Prove that `mirror` push does not delete destination-only entries; record the output for the PR

## 2. Protection store and enforcement

- [ ] 2.1 Add `REPLICA_PROTECTED` (`replica/protected`) and `protectedModels()`, `isProtected()`, `protect()`, `unprotect()` to `Helper/Replica.php`; log each change
- [ ] 2.2 Add `protected` to `GET /api/replica/manifest`
- [ ] 2.3 Answer 423 with the protected names in `POST /api/replica/items/{model}` and `POST /api/replica/models`
- [ ] 2.4 Refuse pull writes into locally protected models in `pull()`
- [ ] 2.5 Bump `Replica::VERSION` to 1.1.0

## 3. Source behaviour

- [ ] 3.1 Read `protected` from the manifest in `push()`; skip those models, add the `protected` counter to results and log
- [ ] 3.2 Turn a 423 from `pushItems()`/`pushModels()` into a protected result; keep throwing on other errors
- [ ] 3.3 Message for peers without `protected` in the manifest and for core destinations
- [ ] 3.4 Show protected models in the dry-run plan

## 4. Admin: Protected view

- [ ] 4.1 Add `GET`/`POST /replica/api/protected` in `Controller/Api.php` with `replica/manage` and CSRF
- [ ] 4.2 Add the Protected view in `views/index.php`: one switch per local model, who protected it and when; end-user copy, no technical notes

## 5. Diff

- [ ] 5.1 Implement the normalised content hash and use it in `planRemote()` (`same` state)
- [ ] 5.2 Implement `Replica::diff()` with the five states, id map matching for core targets and protected flags
- [ ] 5.3 Add `Command/Diff.php` (`replica:diff <target> [model] [-v]`) and register it in `cli.php`
- [ ] 5.4 Add `GET /replica/api/diff/{id}` and the Compare view (tabs per state, checkboxes on `only-here`/`newer-here`)

## 6. Selective push

- [ ] 6.1 Add the `ids` option to `push()`; require a model; report unknown ids
- [ ] 6.2 Add `--ids` to `Command/Push.php` and the `ids` parameter to `POST /replica/api/run/{id}`
- [ ] 6.3 Push the selection from the Compare view

## 7. Verification in the sandbox

- [ ] 7.1 Every scenario in `specs/replica-model-protection/spec.md` against a peer, including a 1.0.0 source against a 1.1.0 destination and the reverse
- [ ] 7.2 Every scenario in `specs/replica-diff/spec.md` against a peer and a core target, with entries from Blog, Webapp, Forms and Analytics models
- [ ] 7.3 Test the Compare and Protected views in a browser; capture screenshots for the PR

## 8. Docs and release

- [ ] 8.1 Update `src/addons/Replica/README.md` (protection, diff, `--ids`, endpoints, 423, limits)
- [ ] 8.2 Update the Replica card in `docs/index.html` if the summary changes
- [ ] 8.3 Bump `src/VERSION`; add a CHANGELOG entry noting the CMS rebuild and the destination-first upgrade order
