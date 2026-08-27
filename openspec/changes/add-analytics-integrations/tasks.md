## 1. Decide the first providers

- [x] 1.1 Confirm which providers ship in the first release — GTM and PostHog are certain; do not guess at others
- [x] 1.2 For each, record the official snippet and the exact configuration it needs (GTM: a container id; PostHog: a project key and an api host), and the format each key takes, in `src/knowledge/`
- [x] 1.3 Decide the environments field's shape — a list of environment names, or a production/all switch

## 2. The Cockpit addon — model

- [x] 2.1 Create `src/addons/Analytics/` with `bootstrap.php`, mirroring how `Blog` registers its helper and admin hook
- [x] 2.2 Implement `ensureModels()` for one collection: `provider` (select), `config` (object), `enabled` (boolean), environments, skipping a model that already exists
- [x] 2.3 Rebuild the model registry cache after creating, so the model is visible with debug off — see `src/knowledge/cockpit-model-registry-cache.md`
- [x] 2.4 Populate the provider select from the providers that have a plugin, so an unrenderable entry cannot be saved
- [x] 2.5 Add the permission and the sidebar entry, with an icon
- [x] 2.6 Verify against a real Cockpit that a fresh install creates the model and that re-running leaves an edited one untouched

## 3. The Cockpit addon — validation and screen

- [x] 3.1 Validate each provider's configuration on `content.item.save.before` against that provider's documented key format
- [x] 3.2 Refuse any value containing quotes, angle brackets or backslashes, independently of the escaping the application does
- [x] 3.3 Add the admin screen listing provider, state and environments, gated on the permission
- [x] 3.4 Verify by executing: a malformed key is refused, a well-formed one saves, an unknown provider cannot be stored, a user without the permission gets nothing
- [x] 3.5 Write `src/addons/Analytics/README.md` — the model, the providers supported, what adding a new provider requires, and that keys here are public values, not secrets

## 4. Reading the integrations in the application

- [x] 4.1 Read the enabled integrations through the CMS client — `enabled` filtered server-side (a plain equality Cockpit forwards); the environment match done in Go rather than assuming how Cockpit forwards a two-way filter
- [x] 4.2 Expose them to templates as a template function, the way `assetURL` is exposed — no handler passes them
- [x] 4.3 Return nothing, without failing the page, when the collection is empty or the CMS cannot be reached
- [x] 4.4 Add tests: integrations present, none configured, CMS unreachable, an entry disabled, an entry for another environment

## 5. The component and the layout

- [x] 5.1 Add an `analytics.html` component to both flavors defining a head block and a body block, identical in content
- [x] 5.2 Emit the configuration as a JSON data block — never interpolated into JavaScript, never through `safeHTML`
- [x] 5.3 Dispatch to each provider through an explicit comparison chain, since `html/template` does not accept a template name from a variable
- [x] 5.4 Call both blocks from both layouts, head and before `</body>`
- [x] 5.5 Emit nothing at all — no empty tags, no empty JSON block — when no integration applies
- [x] 5.6 Verify a value containing quotes and a closing script tag renders inert

## 6. The client scripts

- [x] 6.1 Add `static/js/analytics/init.js`: read the JSON block, build the plugin list, mount the library once
- [x] 6.2 Write one plugin per provider under `static/js/analytics/`, as plain objects with no imports
- [x] 6.3 Get `loaded()` right per provider — report ready only once the provider can accept events
- [x] 6.4 Pin the library to `analytics@0.8.19` in both layouts, and make the load order deterministic
- [x] 6.5 Keep the plugins free of conditionals and transformations: this is the only code here without automated tests
- [x] 6.6 Verified in a browser on analytics-draft: the library mounts, the GA4 plugin builds and `googletagmanager.com/gtag/js?id=...` loads. Took six fixes to get there — see the 0.46.x entries

## 7. Cache invalidation

- [x] 7.1 Add site-wide invalidation for a project, scoped so a shared Redis is never flushed across projects
- [x] 7.2 Trigger it when an analytics entry is saved
- [x] 7.3 Fix the blog's purge hook: `default: return nil` assumes an unrecognised model is irrelevant, which is wrong for anything in the layout
- [x] 7.4 Confirm the purge endpoint's authentication and fail-closed behaviour are unchanged from v0.43.0
- [x] 7.5 Add tests: adding an integration invalidates the home page and a blog page; another project's keys survive

## 8. Distribution

- [x] 8.1 Offer `Analytics` in the addon prompt and in `--addons`
- [x] 8.2 Ship the client scripts as part of the application templates, so `gosite sync --app` delivers them and a customised one is preserved and reported
- [x] 8.3 Declare the addon's application-side requirements so `gosite addons add` refuses an install that would not work
- [x] 8.4 Confirm the install touches nothing else

## 9. Verify end to end

- [x] 9.1 Scaffold a throwaway project with the addon and confirm it works with no manual step
- [x] 9.2 Walked the spec scenarios against the sandbox and, for the browser-dependent ones, against analytics-draft
- [x] 9.3 Confirm a development environment does not load a production-only integration
- [ ] 9.4 On one real project, with one provider, confirm events arrive **in that provider's dashboard** — a script tag being present proves nothing

## 10. Ship

- [x] 10.1 Bump `src/VERSION`
- [x] 10.2 Update `docs/index.html` (an addon card, the built-in count) and `README.md`
- [x] 10.3 Add a CHANGELOG entry stating both rebuilds are needed, CMS and application
- [x] 10.4 Tag the release and publish it with both assets
- [ ] 10.5 Roll out to one project, add the second provider there, and only then the rest
- [ ] 10.6 Open the consent task — analytics is now loading on client sites without it
