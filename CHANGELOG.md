# Changelog

## 0.49.4 — a transient CMS answer no longer fails the page

### Fixed

- **`412 Precondition Failed` from Cockpit failed the render outright.** The
  items endpoint answers 412 when the model it looked up is not a collection,
  which is exactly what a model registry emptied by a cache flush looks like
  from outside. The same request a moment later succeeds - so an editor
  clicking *Clear cache* turned into `could not load the page` for the next
  visitor of a blog index.

  The CMS client now retries once, after 300ms, on 412, 502, 503, 504 and on a
  connection that could not be made. A 404, 401 or 403 is not retried: a wrong
  request is not worth repeating.

  One retry, not a loop. If Cockpit is genuinely down, retrying harder only
  holds the request open for a visitor who will be served the stale copy
  anyway.

  This closes a gap between two paths that behaved very differently: a failed
  `Singleton` already degraded to template fallbacks, so the home page never
  showed an error, while `Items` returned the error straight up the stack - and
  the blog index was the page customers actually saw fail.

## 0.49.3 — publishing must never show a visitor an error page

### Fixed

- **A cache purge caused a 502 for the next visitor.** The scaffold keeps a
  stale copy of every rendered page for exactly one reason - to serve it when a
  render fails - and the purge deleted it along with the fresh one. So the
  moment an editor published, the fallback vanished, and if Cockpit was still
  rebuilding its model registry it answered `412 Precondition Failed` and the
  visitor got `could not load the page`.

  `Purge` now drops only the fresh entries and `PurgeGroup` skips the `:stale`
  keys as it scans. A stale copy is never served while a fresh one exists, so
  this costs nothing on the happy path. `PurgeIncludingStale` and
  `PurgeGroupIncludingStale` remain for when the stale copy is itself the
  problem - a page cached from a bad render.

  Verified by stopping Cockpit outright: with the stale copy the visitor gets
  the real page and a 200; without it, a 502.

- **`APP_URL` in `docker-compose.prod.yml` pointed at a container that does not
  exist there.** 0.49.2 fixed the local collision by naming the container, and
  that fix was wrongly carried into the production compose - which sets no
  `container_name` and is deployed one stack per network, where the service
  name `app` is already unambiguous. Production is back to `http://app:8080`,
  with a comment on both files explaining why they differ on purpose.

- **The purge token is trimmed on both sides.** A secret pasted into a
  deployment UI usually arrives with a trailing newline, and the comparison is
  byte for byte - a 401 while both halves look identical in the dashboard. The
  CMS also says which half is wrong now, instead of only reporting the status.

## 0.49.2 — Clear cache reaches the app, and stops reaching the neighbours

Wiring Cockpit's *Settings → Clear cache* to the application's purge turned up
two faults that had been quiet for a while.

### Added

- **Cockpit's Clear cache now purges the application too.** The Webapp addon
  hooks `app.system.cache.flush`: it rebuilds the model registry and reads one
  real item to reopen the database connection, *then* tells the app to purge
  everything (`{"scope":"all"}`).

  Warm first, purge second - the reverse of how it reads. A purge makes the
  application re-render immediately, and a re-render arriving while the model
  registry is still empty gets 404 for every model and answers with an error
  page. Warming first costs one query and closes that window.

- **`scope` on the purge endpoint**, so the CMS can say "everything" when there
  is no single model to name. The on-page button and an older CMS send no body
  and keep their previous behaviour.

### Fixed

- **A project's cache purge landed on another project's site.** The compose
  files set `APP_URL=http://app:8080`, but every gosite project has a service
  called `app` and they all share `gosite-network`, so `app` resolved to
  whichever neighbour Docker picked. On a host with three projects the name
  answered with three different addresses, and avanxo-dev's purge was clearing
  analytics-draft's cache. `APP_URL` now names the container.

- **SEO cache keys were shared across every project on the host.** The comment
  said the prefix namespaced them per project; the value was just `"seo:"`. One
  site read and overwrote another's `seo:defaults` - a real cross-site content
  leak - and `PurgeAll`, which sweeps the project prefix, never cleared them.
  The prefix now carries the project name, pinned by a test.

## 0.49.1 — HEAD answers on every GET route

### Fixed

- **A HEAD request got 405 on every page.** Echo v5 leaves `AutoHandleHEAD`
  off, so a route registered with `e.GET` refused HEAD outright — and an uptime
  check or link validator that pings with HEAD reported a perfectly healthy
  site as broken. The scaffold's router now builds echo with
  `AutoHandleHEAD: true`: HEAD matches the GET handler, the headers come back
  intact and the body is suppressed, per HTTP semantics.

  Safe for what this scaffold serves: every GET is a cached, public,
  side-effect-free page, and anything that mutates state is a POST, which HEAD
  still cannot reach. Echo disables it by default because the GET handler runs
  in full for each HEAD — worth re-reading its caveats before adding a GET
  route that writes, counts, or costs real work.

  Covered by `internal/app/router_test.go`, which asserts both halves: HEAD
  reaches a GET route with no body, and never reaches a POST one.

## 0.49.0 — `gosite sync` is gone

### Removed

- **The `sync` command, and `src/commands/cmd_sync.sh` with it.** It decided
  file by file whether gosite still owned something, and on a real project that
  produced upgrades which compiled and were still wrong — a preserved file
  needing the same change as a refreshed one, a template quietly replacing
  markup somebody had tuned. The failure was always silent, which is the part
  that made it worse than no command at all.

  Upgrading an existing project is now a deliberate, reviewed pass, written
  down in `MIGRATIONS.md`: read the manifest to find what the project's authors
  edited, three-way merge those files against the template of the version the
  manifest records, copy the rest, then diff the rendered pages before and
  after. That is what the last upgrade actually did, by hand, and it caught
  three regressions the build and the test suite were silent about.

  `.gosite/manifest.tsv` stays. It is still the record of what gosite wrote and
  the hash it had, which is exactly what tells you where the local work is.

### Changed

- **`gosite addons add` no longer borrows from the sync script.** The two
  functions it needed — installing an addon's CMS half and rendering its
  application pages behind the manifest guard — moved to `lib/templates.sh` as
  `install_addons_into_project` and `install_addon_overlays`, next to the addon
  primitives that were already there.

- **Docs no longer point at a command that does not exist**: the website's
  command table, the README, and the `ARCHITECTURE.md`, `README.md` and
  `MEMORY.md` that ship into every generated project. `gosite doctor` and
  `gosite infra` suggested `gosite sync` as the fix for two findings; they now
  name the actual edit.

## 0.48.1 — two SEO regressions found by migrating a real site

Both were introduced by 0.48.0 and both only show on a blog post, which is why
the build and the test suite were quiet about them.

### Fixed

- **Blog posts advertised themselves as `og:type: website`.** `seo.merge()` was
  written before `Data.Type` existed and never carried it, so the "article" a
  post declares was dropped on the way to the layout.

- **`og:image` on a blog post was built without a separator.** `AssetBaseURL()`
  is trimmed of its trailing slash and a Cockpit asset path has no leading one,
  so concatenating them produced `.../assets2026/08/28/cover.png`. Blog images
  now go through a join that owns the separator.

### Added

- **`MIGRATIONS.md`** — what `gosite sync` cannot decide for you when taking an
  existing project to a newer gosite. The 0.48.0 section covers the addon swap
  that has to happen in one move, the three files to merge rather than
  overwrite, the language trap that silently turns a Spanish site into
  `lang="en"`, and how to update the manifest so a later sync does not undo a
  hand-merge.

## 0.48.0 — one Webapp addon, and a site that can describe itself

Six infrastructure addons became one, and the SEO that projects were writing by
hand became content an editor owns.

### Added

- **The `Webapp` addon.** It replaces `AssetPathFix`, `AssetsUpload`,
  `CachePurge`, `CloudStorage`, `ModelManager` and `StarterContent` — the same
  work, one folder, one admin screen. It creates two models on first admin
  load: the `webapp` singleton (site-wide SEO defaults) and the `seoPages`
  collection (per-path overrides).

- **Four routes served from the CMS**: `/robots.txt` and `/llms.txt` emit their
  fields verbatim, `/favicon.ico` redirects to the favicon asset, and
  `/sitemap.xml` is built at request time from `seoPages` minus the entries
  marked `noIndex`. Features that mount their own pages contribute paths
  through `handlers.OnSitemap`, the same arrangement as `OnPurge`.

- **A document head an auditor recognises**: canonical and `og:url`, `og:type`,
  `og:locale`, `<html lang>`, `meta author`, `meta publisher`, `twitter:site`
  and `twitter:creator`, and `meta robots` on every page rather than only when
  a page opts out of indexing — absent, the tag cannot be told apart from
  nobody having thought about it.

- **JSON-LD with a floor.** Leave the field empty and the app emits a minimal
  schema.org `WebSite` built from the other defaults, with the publisher as a
  nested `Organization`. Write your own and it is used untouched: rewriting an
  editor's JSON behind their back is the kind of magic nobody can debug later.

### Fixed

- **Assets rendered as "Not set" everywhere.** A Cockpit asset path is relative
  to the uploads root and carries no leading slash, and with S3 storage the
  file is not on the app's origin at all. Both halves resolved it wrong: the
  admin screen called `pathToUrl()`, which only maps local app paths, and the
  app emitted the bare path — so `og:image` and `rel="icon"` were relative URLs
  that 404'd, and a favicon that was set displayed as missing. The screen now
  uses `fileStorage->getURL("uploads://…")` and the app joins the asset base
  without depending on a leading slash.

- **`llmText` was a wysiwyg**, so text served verbatim to LLM crawlers arrived
  wrapped in `<p>`. It is a plain textarea now, and existing projects are
  migrated in place.

### Changed

- **The Webapp admin screen lists whatever the model defines**, one row per
  field, instead of a fixed set of rows. A field added to the model appears
  without the screen being touched. Fields nobody wants to write by hand link
  out to a generator while they are empty.

- **Model migrations run on admin load.** `ensureModels()` only ever created
  what was missing, so a project scaffolded before a field changed kept the old
  definition forever. Migrations are idempotent and never touch stored entries.

## 0.47.0 — sync could leave a project that does not compile

Three faults, found by walking a real project through the upgrade path rather
than reading it.

### Fixed

- **`gosite sync --app` could leave a project unable to build, silently.** The
  manifest guard decides file by file, but Go source is not a set of
  independent files. On a real project it refreshed `app.go` and
  `internal/analytics/` while preserving a hand-edited `render.go` — every
  decision correct on its own, the result `undefined: views.Integration`, and
  nobody found out until deploy.

  `--app` now checks that the project still builds and, when it does not,
  prints the compiler's own words and names the likely cause: a preserved file
  needing the same change as a refreshed one. Best-effort and never fatal —
  the files are already written, so failing there would only hide what was
  done.

- **`create` never recorded `internal/` or `static/` in the manifest.**
  `managed_files()` carried a hardcoded list written before `--app` existed, so
  every application source looked unmanaged: a hand-edited one could be
  overwritten without warning, and the "preserved vs refreshed" split above had
  nothing to go on.

  The list is now derived from the template tree itself — base, both flavors
  and every addon overlay — so it cannot drift out of step again. A project's
  own handlers, pages and images stay out of it.

- **A file gosite has no record of writing is preserved, not overwritten.**
  Unknown provenance is a reason to be careful, not a licence. `--force` still
  takes the template version.

- **The stray `REQUIRES` in project roots is cleaned up.** 0.46.x stopped
  creating it; `sync` now removes the ones already out there, and only when the
  file is byte-identical to one gosite ships.

## 0.46.14 — mounting waited for nothing, and threw

### Fixed

- **`Cannot read properties of null (reading 'appendChild')`, from inside the
  Google Analytics plugin.** The loader sits in `<head>` so the bundles start
  downloading as early as possible — but at that moment `document.body` is
  still `null`, and that plugin appends its tag straight to `document.body`.

  Mounting now waits for `DOMContentLoaded` when the body is not there yet.
  Only the mount waits: the downloads still start immediately, and the queue
  added in 0.46.6 holds any event the page raises meanwhile, so nothing is lost
  to the delay.

  The loader's test now runs the way a real page does — no `body` at script
  time, `DOMContentLoaded` afterwards — which is what makes this the last
  failure of its kind rather than the next one.

## 0.46.13 — the core library publishes `_analytics`, not `Analytics`

### Fixed

- **Nothing was ever tracked: the loader could not find the library.** The core
  bundle publishes `_analytics` — an object holding `{Analytics, CONSTANTS,
  EVENTS, default, init}` — and the factory is `_analytics.init`. The loader
  looked for a bare `window.Analytics`, did not find it, and reported that the
  library had not loaded while it was sitting there fully loaded.

  That is a bad failure to have: it reads as an ad blocker, which sends you
  looking at the network tab rather than at the code.

  Both shapes are accepted now, so a bundle that changes its mind does not
  break this again.

- **The test agreed with the bug rather than catching it.** It stubbed
  `window.Analytics`, inventing the shape the code assumed. The stub now
  mirrors the real bundle. This is the second time today a mock encoded the
  same misunderstanding as the code it was meant to check; the rule that comes
  out of it is that a stub of a third-party contract has to be built from that
  contract, not from what the caller hopes it is.

## 0.46.12 — the loader also says when the library is blocked

### Changed

- Completes 0.46.11: a blocked or missing `analytics` library now says so
  rather than sharing the silent "nothing configured" path. An ad blocker is
  the most likely reason a page has integrations and sends nothing, and it
  should not look like a configuration mistake.

## 0.46.11 — the site loader says whether it is tracking

### Changed

- **The browser loader reports success, not only failure.** It used to log
  nothing on the happy path, so an empty console meant any of four very
  different things: nothing configured, the library blocked, no plugin built,
  or everything working. All four look identical while debugging, and that
  ambiguity has now cost more time than any of the bugs behind it.

  A page with analytics logs one line naming what it mounted
  (`[analytics] tracking with: google-analytics`). A library that failed to
  load, and a set of integrations that produced no usable plugin, each say so.

## 0.46.10 — Google Analytics never loaded

### Fixed

- **Two official plugins expose an ESM interop object, not the factory.**
  `google-analytics` and `google-analytics-v3` set their global to
  `{default: fn, ...}`; the other seven set the function directly. The loader
  called the global, found it was not callable, and skipped the provider — the
  bundle loaded, the global existed, and no request ever reached Google. The
  loader now unwraps `.default`, which is cheaper than maintaining a list of
  which bundles do that.

- **`measurementIds` has to be a list.** It is plural because the GA4 plugin
  iterates it, and a lone string there loads the plugin and sends nothing, with
  no error anywhere. Keys declared as lists are wrapped on save, and the config
  template now offers `[""]` so the shape is visible before anything is typed.

Both were found by running the real bundles rather than reading them: the
loader is now exercised against the published files, mounting GA, GTM, several
providers at once, and one unknown provider that must not take the others down.

## 0.46.9 — the config block was JSON-encoded twice

### Fixed

- **The page carried the integrations and loaded none of them.** The
  configuration block held a JSON *string* rather than JSON:

  ```html
  <script type="application/json" id="analytics-config">"[{\"Provider\":\"...\"}]"
  ```

  `toJSON` returns a plain string — deliberately, so that in an Alpine
  attribute `html/template` escapes it — but inside a `<script>` element that
  same escaping turns it into a JavaScript string literal. `JSON.parse` then
  returned text instead of an array, the loader found nothing to mount, and the
  page looked exactly as though analytics had never been configured.

  A separate `jsonData` helper emits it verbatim for data blocks. That is safe
  rather than a hole, and the reason is worth stating: `encoding/json` escapes
  `<`, `>` and `&` to `\u003c`, `\u003e` and `\u0026` by default, so no value
  can close the script element or open a tag. The escaping that matters still
  happens, one layer down, where it belongs. `toJSON` is unchanged for
  attributes.

  Two tests now cover it: the block must parse as an array, and a value
  carrying `</script><img onerror=...>` must not become markup.

## 0.46.8 — the config box now shows what was filled in

### Fixed

- **The config template was written but never displayed.** The value was set
  correctly — the console said so — yet the Configuration box stayed empty,
  which from the outside is indistinguishable from nothing happening at all.

  Cockpit's object field only repaints from an external change when
  `this.code.editor` exists, and it looks that element up **once**, in
  `mounted()`, while the code editor is an async component that has not
  rendered yet. So `this.code` is `null` for the life of the field and the
  watcher can never fire: the value changes, the box does not.

  `field-code` publishes its editor on its own element
  (`this.$el.editor = this.editor`), which is the handle now used to do what
  that watcher would have done. Nothing is reached into that was not offered,
  and an editor that has focus is left alone — whoever is typing wins.

### Changed

- **The script reports each step it takes** (`console.debug`, visible at
  Chrome's *Verbose* level). This feature failed three times in ways that all
  looked identical from the outside — not deployed, not hooked, hooked but
  silent — and each time the silence cost more than the bug. Now every branch
  says which one it took.

## 0.46.7 — the config template actually fires

### Fixed

- **Selecting a provider did nothing.** The 0.46.6 script read the event payload
  one level too high: Cockpit's `App.trigger(name, params)` hands handlers
  `{name, params}`, so the form is at `event.params.form`, not `event.form`.
  Undefined, an early return, and a feature that was deployed, served, and
  inert.

  The test did not catch it because the mock encoded the same misunderstanding
  as the code — it fired `cb({form})`, matching the bug rather than Cockpit. It
  now mirrors the real `trigger` implementation, which is the only version of
  that mock worth having.

  An unexpected payload now logs a warning instead of returning quietly. The
  original failure looked exactly like a deployment problem for as long as it
  stayed silent, and that cost more time than the bug did.

## 0.46.6 — the editor fills in the right keys for you

### Added

- **Choosing a provider pre-fills `config` with the keys it expects.** Pick
  Google Analytics and the field becomes `{"measurementIds": ""}`; pick GTM and
  it becomes `{"containerId": "GTM-"}`. The system already knew every provider's
  shape — the screen validated against it and the README listed it — so making
  an editor retype key names from memory was the actual cause of a GTM container
  id ending up under Google Analytics.

  The templates come from the same rules the screen validates against, so what
  the editor is offered and what is checked cannot drift apart.

  It hooks `fields-renderer-init`, the event Cockpit's field renderer fires with
  itself, rather than poking at the DOM. And it is deliberately conservative:
  it writes into `config` only when that cannot destroy anything typed. A field
  filled in by hand survives a change of provider untouched — better a stale key
  the screen complains about than lost work.

## 0.46.5 — a wrong key is a message, not a 500

### Fixed

- **A configuration mistake in the Analytics editor answered `500 system
  error`.** Putting a GTM container id under Google Analytics, or leaving a
  required key out, refused the save — and the reason never reached the editor.

  The cause is structural, not a slip: Cockpit turns **any** uncaught exception
  from a save hook into `{"error":"500","message":"system error"}`
  (`index.php:156`). Core's own validation has the same fate. So refusing a save
  is refusing it *silently*, which reads as a broken CMS rather than as "you
  typed the wrong key".

  Validation therefore moved from the save to the screen. An entry is stored as
  typed, and the Analytics screen shows exactly what is wrong next to it —
  `Missing "measurementIds"` · `Unused here: id. Google Analytics 4 expects
  measurementIds` — with a link to that provider's documentation. A column says
  at a glance whether each entry is usable, and the site loads only the ones
  that are.

  Genuinely hostile input — quotes, angle brackets, backslashes — is still
  refused outright. That costs an opaque 500, which is the right trade for
  input that has no business in a page.

  Saving an untouched draft, an unknown provider and a malformed key all store
  cleanly now and report themselves instead of exploding.

## 0.46.4 — saving an integration no longer answers 500

### Fixed

- **Every save from the Analytics editor returned a 500.** Cockpit's `select`
  field emits an **array**, always — its `select()` does
  `if (!Array.isArray(val)) val = []` and then pushes — so `provider` arrived as
  `["posthog"]`, not `"posthog"`. Casting that to a string produced `"Array"`,
  which is not a known provider, so validation refused it. Nothing catches a
  validation exception on the way out (core's own uniqueness check has the same
  fate), so it surfaced as a 500.

  Select values are now folded to the scalar behind them and stored that way,
  so the site reads a plain string too. Verified against the payload the editor
  actually sends, which is what the original tests never did: they passed
  strings and so never met the bug.

- **Saving a new entry before filling it in exploded.** An untouched draft — no
  provider, no configuration — is now allowed through. It renders nothing and
  the screen shows it as incomplete, which beats an error page for clicking
  save too early. A provider that is set but wrong is still refused.

### Added

- **`qa` as an environment**, covering `qa`, `staging`, `stage`, `acceptance`,
  `uat` and `test`.

  Without it, "anything that is not development" meant production — so a
  staging site loaded the client's **production** keys and filled their real
  analytics with test traffic. That is worse than no tracking, because the data
  looks legitimate.

  `APP_ENV` is folded to one of `development`, `qa` or `production`; anything
  unrecognised, empty included, is production. Deliberately separate from
  `config.IsDev()`, which decides whether the cache-purge endpoint may skip its
  token: folding staging in there would leave purging unauthenticated on a
  staging site. The two questions look alike and must not share an answer.

## 0.46.3 — the Analytics screen says what each provider needs

### Added

- **A reference table on the Analytics screen**: every provider, the keys its
  `config` requires, and a link to where that provider's full option list is
  documented. Links rather than copies — those options belong to each plugin
  and a copy here would go stale the first time upstream changed one. The
  `config` field's help text points at the same index.

### Fixed

- **The screen claimed to know whether an integration was live, and did not.**
  It compared each entry's environment against the **CMS container's**
  `APP_ENV` — which is never set, because the website and the CMS are separate
  services and only the website reads it. Every entry therefore read
  "not live in (unset)", which was both wrong and confidently stated.

  The screen no longer guesses. It shows whether an entry is enabled, and
  explains that "applies to" is matched against the *website's* environment.

## 0.46.2 — a new provider now reaches projects that already exist

### Fixed

- **Adding a provider never reached a project that already had the model.**
  `ensureModels()` leaves an existing model completely alone, which is right for
  anything an editor owns — but the provider list is not that. It is derived
  from code, so a project created on 0.46.0 stayed frozen at two providers no
  matter how many later releases added, and a CMS rebuild changed nothing.

  The addon now brings that one field's options up to date on admin load, and
  nothing else: labels, other fields and anything an editor changed are
  untouched, and no write happens when the list already matches. Verified
  against a real Cockpit, including that a renamed field label and an edited
  model description both survive.

### Upgrading

For a project that already has the Analytics model, the list appears after a
CMS rebuild — a restart is not enough, because the addon is baked into the
image:

```bash
gosite addons add Analytics <project>   # refresh the addon files
gosite restart <project> --build
```

Then open the CMS admin once: the update happens on admin load.

## 0.46.1 — nine providers, not two

### Fixed

- **The Analytics addon offered two providers when it could offer ten.** The
  0.46.0 design rested on a check that concluded no official `analytics` plugin
  publishes a browser bundle. That check looked for
  `dist/analytics-plugin-<name>.min.js`, got 404s, and read absence into them.

  The real path repeats the scope — `dist/@analytics/<name>.min.js` — and nine
  of the fourteen official plugins load standalone and expose a global,
  verified by evaluating each one and calling it. So the hand-written GTM
  plugin was replacing a maintained official one for no reason.

  The select now offers **Google Tag Manager, Google Analytics 4, Google
  Analytics (Universal), Mixpanel, Segment, Amplitude, HubSpot, FullStory,
  Customer.io and PostHog**. Only PostHog is ours, because it genuinely has no
  official plugin.

  Four published plugins are deliberately absent: `aws-pinpoint`, `intercom`
  and `snowplow` ship bundles referencing code they do not include, and
  `simple-analytics` publishes no browser build. Each reason is recorded in
  `src/knowledge/analytics-providers.md` so nobody adds them back assuming an
  oversight.

### Changed

- **One loader file instead of a script per plugin.** The component emits the
  configuration and two script tags; `static/js/analytics/analytics.js` decides
  which bundles to fetch from that JSON. Adding a provider is a line in its
  registry plus an option in the CMS — **never a template change**. The chain
  of per-provider comparisons in the component is gone, along with the reason
  it existed.
- **Events raised before the bundles arrive are no longer lost.** The loader
  installs a queue standing in for `window.analytics` and replays it on mount.
- **Configuration is stored under each provider's own key names** and handed to
  the plugin untouched, so there is no translation layer to drift. GTM's field
  is `containerId`, which is what its plugin calls it — **not** `id` as 0.46.0
  stored it.

### Upgrading

Only affects projects that already added a GTM integration on 0.46.0: rename
its `id` key to `containerId`. Nothing else changes.

```bash
gosite sync <project> --app
gosite restart <project> --build
```

## 0.46.0 — analytics keys as content

### Added

- **New `Analytics` addon**, opt-in. Third-party tracking keys — Google Tag
  Manager, PostHog — live in the CMS as content rather than in a layout five
  projects edit separately.

  One collection, one entry per integration: the provider, that provider's
  configuration, whether it is on, and where it applies. **Adding a key is
  data**, done by whoever owns the site, with no release. Adding a *kind* of
  tool stays a visible change to the base, because something has to know how to
  render it — which is why `provider` is a closed select and an entry the site
  cannot render cannot be saved at all.

  Each entry says whether it applies to `all`, `production` or `development`,
  so local browsing never lands in a client's production account.

  **Keys reach the browser as data, never as code.** They are emitted as a JSON
  block a local script reads, so nothing an editor typed is ever interpolated
  into JavaScript: a malformed value fails a `JSON.parse` instead of executing,
  and no inline executable script is needed. Values are also validated on save
  — the two defences are independent, so a mistake in one is not a
  vulnerability.

  The scripts are `analytics` plugins loaded from a **pinned** CDN version. No
  official plugin publishes a browser bundle, so GTM and PostHog have small
  plugins of our own under `static/js/analytics/`, which is roughly the work a
  hand-written snippet would have been plus a uniform `track` / `page` /
  `identify` API. `@analytics/posthog` does not exist and the third-party ones
  were last published in 2024.

  Integrations reach every page through a template function rather than each
  handler's data, so a page added later cannot silently lose its tracking.

  Consent management is deliberately **not** in this release. It is the next
  task, and tags load unconditionally until it lands.

### Changed

- **A change to site-wide content now purges every cached page.** Invalidation
  assumed an edit affects one area — the home page purges itself, a feature
  purges its own. That does not hold for anything in the layout, which is on
  every page: without this, the home page would update and every blog page
  would serve the old keys for the rest of its cache window. The purge is
  scoped by project prefix, so a shared Redis is never flushed across projects.
- **`gosite sync --app` now covers `static/` as well as `internal/`.** The
  browser assets gosite ships live there, and leaving them out meant an addon's
  client scripts never arrived — found by running the upgrade path rather than
  reading it.
- `views.NewRenderer` takes options instead of a widening parameter list, so a
  project that has customised its `app.go` keeps compiling when it syncs.

### Fixed

- **A stray `REQUIRES` file was copied into the root of every project created
  with an addon that has an application half.** It describes an addon to
  gosite and has no business in a project. Introduced in 0.45.0; the rendered
  fixture now fails if it reappears.

### Upgrading

```bash
gosite sync <project> --app       # internal/ and static/
gosite addons add Analytics <project>
gosite restart <project> --build  # both halves are compiled or baked in
```

`addons add` refuses with a precise list if the application half is missing.

## 0.45.4 — the website caught up

### Changed

- **`docs/index.html` and `README.md` now describe what gosite actually does.**
  The site still said every project shipped *four* built-in addons (it is six),
  had no card for `CachePurge` or `StarterContent`, and — the one that cost
  real debugging time — claimed addons were "bind-mounted in dev, baked into
  the production image". They are baked into the image in **both**, which is
  why adding one needs a rebuild rather than a restart. That is now stated
  where somebody looking for it would read it.

  Also documented: `gosite addons`, `gosite sync --app`, the `router_blog.go` /
  `internal/blog/` files an opt-in addon adds, and that `gosite start` registers
  the API key but no longer creates content models.

## 0.45.3 — a new project brings its own home singleton

### Fixed

- **A fresh project could answer 502 on its front page.** The application reads
  a `home` singleton, and when the CMS has none it returned
  `502 could not load the page` — even though the templates carry fallback text
  written for exactly that case.

  Two separate problems, both fixed:

  **The singleton was created from the CLI, over HTTP, after boot.** `gosite
  start` waited up to 90s for the REST API, registered an API key and POSTed to
  `/api/models/save` with retries. That depends on the CMS being up, on a token
  existing and on timing — and when any of those was untrue it failed silently.
  Combined with 0.45.1's missing `.env` (no token), it failed silently a lot.

  A new built-in `StarterContent` addon creates the model from inside Cockpit
  instead: no network, no token, idempotent, and it cannot half-succeed. It is
  the approach Forms and Blog already use for their own models, and it rebuilds
  the model registry cache so the model is visible on non-debug environments. A
  `home` model that already exists is never touched, fields included. `gosite
  start` still registers the API key; it no longer creates models.

  **A missing model was treated like a broken CMS.** The client now reports
  `ErrNotFound` separately, so "nobody has created this yet" renders the
  template's fallbacks with a 200, while an unreachable or failing CMS is still
  a 502. The fallback page is deliberately not cached, so real content appears
  the moment somebody writes it rather than a TTL later. An existing but empty
  singleton is treated the same way.

### Upgrading

New projects need nothing. For an existing project:

```bash
gosite sync <project>          # installs the StarterContent addon
gosite sync <project> --app    # the 502-instead-of-fallbacks fix
gosite restart <project> --build
```

## 0.45.2 — a newly installed addon now actually appears in Cockpit

### Fixed

- **An addon installed into an existing project stayed invisible in the CMS
  panel**, with its files sitting correctly inside the container the whole time.

  Cockpit records which addons exist in `storage/cache/modules.cache.php` and
  rebuilds that list only when its own version or env directory changes —
  never when an addon appears. gosite knew this and cleared the cache on
  install, but at the wrong moment, and the timing made things worse rather
  than better:

  1. `addons add` copies the addon to the host and clears the cache
  2. the CMS is still running the **old image**, which has no such addon, and
     regenerates the cache from it — a stale list, written right then
  3. `--build` finally puts the addon in the image
  4. the container comes up, finds a cache that is still "valid" by Cockpit's
     rule, and reuses it — never seeing the addon

  Clearing before the rebuild does not just fail to help; it guarantees a stale
  list gets written and then survives. The clear now happens as the container
  comes up (`gosite start` and `gosite restart`), which is the only point where
  the image and the cache are guaranteed to agree. Cockpit rebuilds the list on
  the first request.

  This was not new with the blog — Forms and Replica had the same exposure
  whenever they were added to a project after creation.

### Upgrading

For a project whose addon is not showing:

```bash
gosite restart <project>
```

## 0.45.1 — the .env template was never shipped

### Fixed

- **`gosite create` did not write `.env`, and `gosite sync` failed outright**
  with `cp: .../src/templates/.env: No such file or directory`.

  `src/templates/.gitignore` is a template — it is copied into generated
  projects so their `.env` stays out of git. But it sits inside the template
  directory, so **git applied it to gosite's own repository too**, silently
  ignoring `src/templates/.env`. The file existed on the machine it was written
  on and nowhere else: never committed, absent from every release tarball,
  missing from every installed copy.

  Three symptoms, one cause. Without `.env` a new project also had no
  `COCKPIT_API_TOKEN`, so `gosite start` skipped seeding the Cockpit API key
  and the application authenticated with an empty key — which is why a key
  created by hand in the CMS appeared not to work.

  The template is now stored as `dotenv` and written as `.env` on copy, the
  same mapping `gosite.env` → `.gosite.env` already used, so no gitignore
  pattern can match it again. The rendered fixture now asserts that `.env`
  reaches the project, which turns a recurrence into a failing test.

- **The cache-purge button rendered in production.** `home.html` included it
  unconditionally; `IsDev` was passed to the template and never read. The
  button posts without a token, which the purge endpoint accepts only in
  development, so in production it showed every visitor a control that answers
  401. It is now behind `{{if .IsDev}}`, with a test asserting both directions.

### Changed

- **`.env.example` now defaults to `APP_ENV=development`.** It is a local
  development starting point and nothing else: the production compose sets
  `APP_ENV` itself and declares no `env_file`, and `.env` is gitignored, so
  neither file ever reaches a server.

### Upgrading

This affects every project, not only ones using the blog: no `gosite sync`
worked without it. Update gosite, then per project:

```bash
gosite sync <project> --env    # creates .env when missing, adds missing keys
gosite start <project>         # seeds the Cockpit API key from it
```

## 0.45.0 — a blog every site shares

### Added

- **New `Blog` addon**, opt-in like `Forms` and `Replica`, but the first one
  that installs an application half as well as a CMS half.

  **In the CMS.** Four models created on first admin load: `blogs`,
  `blogPosts`, `blogCategories`, `blogAuthors`, grouped under *Blog*. Several
  blogs per site are **data, not schema** — a blog is an entry in `blogs` and an
  article references it, so every project runs the same models and a fix here
  is a fix everywhere. Names are prefixed on purpose: `categories` is a name a
  client will want for their own content, and because installation skips a
  model that already exists the collision would have been silent.

  Slugs are derived from the title, transliterated (`Diseño Gráfico` →
  `diseno-grafico`) and unique **within their blog**, so `/noticias/novedades`
  and `/casos/novedades` can both exist. Cockpit's own `meta.unique` cannot
  express that — it runs an `$or` across the whole collection — so the scoped
  check lives in the addon. A blog slug that collides with a path the scaffold
  serves (`static`, `healthz`, `api`, …) is refused at save time.

  The byline is the article's author reference, falling back to the
  `blogAuthors` entry linked to the Cockpit account that created it. Writing
  your own blog needs no author picked; publishing for a client still lets you
  choose. Only display fields ever leave the addon — never an account's e-mail.

  An admin screen at `/blog` shows what Cockpit's generic editor cannot: each
  article's real address on the public site, plus a manual cache purge.

  **In the application.** Pages at `/{blog}` and `/{blog}/{slug}`, paginated,
  with canonical URLs and Open Graph tags, in both template flavors. Drafts are
  unreachable by construction: Cockpit's read API overwrites `filter._state`
  and never serves an unpublished entry, so nothing here has to filter them.

- **New `gosite addons` command.** Installing an addon into a project that
  already exists was possible before (`gosite sync --addons`), but only if you
  knew `sync` had a flag for it. It is now a command of its own:

  ```bash
  gosite addons list [project]        # the library, and what the project has
  gosite addons add Blog [project]    # install
  gosite addons remove Blog [project] # uninstall
  ```

  Addon names are matched against gosite's library, so the project can be given
  in any position. The implementation is the same one `sync --addons` uses -
  the command is a front door, not a second code path. Removal deletes the
  addon's files, including its application half, and deliberately leaves the
  content it created in the database: dropping models and entries is a data
  decision, not an install one.

- **New `gosite sync --app`.** Every other sync mode promises never to touch
  your Go code, and that promise is worth keeping by default. But gosite's own
  scaffolding lives in `internal/` too — the cache, the CMS client, the
  renderer, the router seam — so a project scaffolded a year ago could not
  install an addon that calls into scaffolding it does not have.

  `--app` brings `internal/` up to the current templates behind the same
  manifest guard as everything else: a file byte-identical to what gosite wrote
  is refreshed, a file you edited is preserved and reported. Handler code you
  wrote survives; plumbing you never opened catches up. Files an addon
  installed are not touched here — refresh those with `gosite addons add`.

- **`gosite addons add` refuses an install that would break the build.** An
  addon's pages call into the project's own Go code, which gosite never
  rewrites. Installing into a project without those seams used to succeed and
  leave a project that did not compile. It now checks first and names every
  file and the exact thing missing from it, installing nothing. Requirements
  are declared by the addon (`REQUIRES`), not hard-coded in the CLI.

### Changed

- **The CMS client can read collections.** `internal/cms` gained `Items` and
  `First` with filter, sort, pagination, projection and populate. Both of
  Cockpit's response shapes decode to one result type — it returns a bare array
  normally but `{data, meta}` when `skip` and `limit` are both present, and
  reading that wrapper as a list yields entries with no `_id`. Reads always
  send both parameters, which makes the shape deterministic and is also the
  only way to get `meta.total`.
- **Cache invalidation can address a group of keys.** A blog is many keys where
  the home page was one, and publishing an article changes its blog's index as
  well as its own page. `CachePurge` now tells the app *what* changed, so the
  app drops that blog and leaves other blogs and the home page cached. The body
  is additive — an older app ignores it and behaves exactly as before — and the
  endpoint's fail-closed authentication from 0.43.0 is unchanged.
- **Page templates register themselves.** Every file under
  `internal/views/pages/` becomes a page named after the file; adding a page no
  longer means editing `render.go`.
- **Optional features mount from their own file.** `router.go` declares a
  `mountFeatures` seam and calls it in plain sight; an addon appends to it from
  a file of its own. Installing a feature into an existing project therefore
  adds files and never rewrites `router.go`, which projects edit by hand and
  `sync` deliberately preserves.

### Fixed

- `gosite sync --list-addons` was documented in the command's help but never
  wired into its argument parser, so it was treated as a project name and
  failed with "Unknown project '--list-addons'".

### Upgrading

Existing projects need their application sources brought up to date first,
because the blog's pages call into scaffolding older scaffolds do not have:

```bash
gosite sync <project> --app       # refreshes internal/, preserves what you edited
gosite addons add Blog <project>  # refuses with a precise list if anything is still missing
gosite restart <project> --build  # both halves are compiled/baked in
``` It only adds files —
a blog page you have edited is preserved and reported, `--force` takes the
template version. Because the addon changes both halves, **rebuild the CMS
image and the application**; restarting is not enough.

## 0.44.0 — replicated models become visible on the destination

### Fixed

- **Replica wrote models that nobody could see.** `applyModels()` stored
  incoming model definitions correctly in the destination database, but
  `Content\Helper\Model` caches every definition under the `content.models`
  memory key and only bypasses that cache when debug is on. On any non-debug
  destination the registry kept describing the world as it was: the REST API
  answered `Model <name> not found` and a consuming app read the singleton as
  empty, while the definition sat correct in the database the whole time.

  `applyModels()` now rebuilds the registry after a successful write. The
  rebuild is best-effort — the data is already stored and the next request
  rebuilds it anyway — so a failure is reported in the run's messages instead
  of failing the replication.

  This affected every gosite project replicating a new model to a non-debug
  target, and stayed hidden for so long precisely because development runs with
  debug on, which rebuilds the registry on every request and masks it
  completely.

  The behaviour is documented in `src/knowledge/cockpit-model-registry-cache.md`
  for every code path that writes model definitions outside the admin UI.

  Replica is baked into the CMS image (`Dockerfile.cms COPY`), so projects need
  a **CMS rebuild**, not a restart.

## 0.43.1 — the Forms config block actually applies

### Fixed

- **The entire `forms` block of `cockpit/config.php` was inert.** The addon
  read its five settings through `config/forms/...`, but `bootstrap.php` builds
  the app with `new Lime\App($config)`, so the config file's top-level keys sit
  at the ROOT of the registry — `forms/...`. All five lookups returned `null`
  and silently fell back to the built-in defaults: `trustedProxies` (every
  submission stored the proxy's IP instead of the visitor's),
  `personal_data_retention` (the 90-day ip/userAgent clearing never applied),
  `collect_personal_data` (collection could not be turned off),
  `allowed_origins` (the public receiver's CORS ignored the list) and the
  deprecated `trustProxy` alias. Reads now go through a `config()` helper that
  tries the root key first and keeps the nested path as a fallback.

  Two notes for existing installations: the addon is baked into the CMS image
  (`Dockerfile.cms COPY`), so this needs a **CMS rebuild** — restarting is not
  enough. And because the retention sweep never ran, existing projects may hold
  IPs and user agents older than their configured window; the first time the
  Forms screen is opened after the rebuild, the daily sweep runs and purges
  them.

## 0.43.0 — templates as real files, submission storage, quality gates

### Note before upgrading (data-affecting)

- **Forms submissions now have a personal-data retention policy.** The `ip`
  and `userAgent` fields of stored submissions are cleared 90 days after
  submission (everything else in the submission is preserved). The window and
  the collection itself are configurable in `cockpit/config.php`:
  `personal_data_retention` (seconds, `0` = keep indefinitely — flagged by
  `gosite doctor`) and `collect_personal_data` (`false` = never store them;
  the rate limit is unaffected, it reads the client address at request time).
  The clearing runs automatically at most once a day when the Forms screen is
  opened. Projects that need the old behaviour must set
  `'personal_data_retention' => 0` before upgrading the addon.

### Changed

- Every generated project file (Go application, views, compose files,
  Dockerfiles, `.env`, docs) is now a real file under `src/templates/` with
  its true extension, rendered by literal `__PLACEHOLDER__` substitution —
  no shell interpretation of template content, ever. `create` and `sync`
  render from the same source and produce byte-identical output; a render
  that leaves a token unresolved fails loudly, naming file and token.
  The template tree is verified in CI (`gofmt`, `go vet`, YAML parse,
  `php -l`) without creating a project.
- Forms admin screen: submission counts now come from a single
  database-side aggregation (exact, regardless of collection size; the old
  count was computed in PHP and capped at 10 000 documents), and forms
  configured but never submitted appear with a count of zero. Column
  derivation inspects a bounded sample (200 newest submissions), stated in
  the interface.
- `gosite update` verifies the downloaded release against the published
  checksum, stages the new tree, backs up the previous installation and
  rolls it back if the new binary does not run. `GOSITE_REPO` from the
  environment is ignored (reported); `--repo <owner>/<name>` is the explicit
  override. Branch installs require `--allow-unverified`.
- New quality gates: shellcheck (severity `warning`) over `src/**`, a
  Docker-free bats suite covering the registry, port allocation, locking and
  project resolution (including the Phase 2 concurrency cases), a template
  fixture job, and an end-to-end smoke job (`create → build → start →
  healthz`) with guaranteed cleanup. The pre-commit hook runs the fast lint
  subset (~0.5 s).

## 0.42.0 — state integrity and a safe update path for existing projects

### Added

- `gosite sync --report`: per-file drift report between a project and the
  current templates — identical / modified / missing, plus a structural
  (`yq`) comparison of the production compose that classifies keys the
  template would add, values that differ, and project-only keys. Read-only;
  `--strict` makes it exit non-zero on drift so it can gate a pipeline.
- Per-project manifest (`.gosite/manifest.tsv`): every file gosite writes is
  recorded with its hash at write time. Sync refreshes files that still
  match, preserves and reports hand-edited ones (unless `--force`), restores
  deleted ones, and never adopts local edits into the manifest. Projects
  from before the manifest adopt one from their current contents on the
  first sync — that pass writes nothing but the manifest and shows the drift
  report instead.
- State handling hardened: all registry/port writes go through a portable
  `mkdir`-based lock (bounded wait, orphan reclamation, trap-driven
  release) and atomic `mktemp`+`mv` publication. Port selection and
  reservation are one indivisible critical section, so concurrent creates
  can never pick the same port; failed creates release their reservation.
  Reading the registry never rewrites it — vanished projects are reported as
  `unavailable` and pruned only by `gosite list --prune`.
- `gosite doctor` now audits every registered project and the shared
  infrastructure against the secure defaults (missing Forms proxy trust,
  empty purge token, wildcard CORS, datastores published beyond loopback,
  unlimited personal-data retention), read-only, with the exact remediation
  command per finding. `--strict` exits non-zero when there are findings.

### Changed

- **`docker-compose.prod.yml` is now read-only for gosite.** No sync mode
  writes it; drift is reported and the human decides. The only write path is
  the explicit `gosite sync --compose-prod --force`, which first copies the
  current file to a timestamped `.bak` beside it.

## 0.41.0 — security hardening of the fail-open paths

### BREAKING

- **`POST /cache/purge` is no longer public.** Without
  `COCKPIT_API_TOKEN` set (outside development) the endpoint answers
  **503** instead of purging; with a wrong token it answers 401. A deployed
  site that relied on the unauthenticated purge will stop purging until the
  variable is set — that is the point: the endpoint was silently open on
  every deployment that lacked the variable. Set `COCKPIT_API_TOKEN` in the
  environment (the `.env` template ships the key) and redeploy; the
  comparison is constant-time. `gosite doctor` detects the empty-token
  condition and names the variable.
- **MongoDB, Redis and MinIO now bind to 127.0.0.1 only.** The shared
  infrastructure's datastores are unauthenticated; binding them to all
  interfaces made them reachable from the network. Host tools that connect
  through `localhost` keep working unchanged. If something on your LAN
  genuinely needs them, set `GOSITE_BIND_ADDRESS=0.0.0.0` (the CLI warns)
  and recreate with `gosite infra up`. Legacy `minioadmin` installations are
  detected and rotated instructions are printed; new installs get generated
  credentials persisted under `~/.gosite/infra/` (mode 0600).

### Changed

- Forms anti-abuse: client identity for the rate limiter is taken from the
  right of `X-Forwarded-For` according to the configured
  `forms.trustedProxies` hops (default 1 behind Traefik), never the
  leftmost (client-forgeable) entry. The legacy boolean `trustProxy` is
  still honoured as `trustedProxies: 1` with a deprecation notice. When the
  memory backend is down, submissions fail closed with 503 + `Retry-After`
  instead of skipping the rate limit. CORS on the public receiver fails
  closed: without `allowed_origins` configured, no cross-origin header is
  emitted.

### Accepted risks

- The **Replica** addon stores peer API keys in plaintext in its target
  configuration (MongoDB), and the **Forms** addon stores the per-form
  `webhookSecret` in plaintext in the `formSettings` collection. Both are
  operator-controlled secrets in a database that also holds the content
  itself; protecting them would mean a key vault with its own secret
  management. Accepted: anyone with database access already has the content
  these secrets protect. Masked in admin output; do not expose the database
  to untrusted parties (see the loopback binding above).
