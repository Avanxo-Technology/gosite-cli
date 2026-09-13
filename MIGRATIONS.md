# Migrations

Upgrade notes for taking an existing project from an older gosite to a newer
one. There is no `sync` command to do it for you — it was removed in 0.49.0
because deciding file by file produced upgrades that compiled and were still
wrong, silently. This is the procedure that replaced it.

Read the section for every version between the project's and the target one.
Find the project's version per file:

```bash
cut -f3 <project>/.gosite/manifest.tsv | sort -u   # a project is usually a mix
```

---

## How to merge a project forward

Learned taking six client sites to 0.53.0 in September 2026. Every point below
is something a build, the test suite or a clean-looking merge let through.

### The manifest's version is a claim, not a fact

A site migrated by hand records the target version on files that were never
brought forward: soyarnold-dev's manifest said 0.49.12 for a home page that is
0.45.0 code. Merging against the claimed version makes every template change the
file missed look like a deletion by the project, and the merge silently drops
it. For each file take as base the template version that reproduces the
manifest hash exactly; failing that, the version whose rendered file is closest
to the project's.

### Old manifests do not cover the application

Manifests written before 0.44.0 track addons, compose and deploy files only -
nothing under `internal/`. There is no drift signal for the code that matters.
Scaffold the project twice in a sandbox, at its old version and the target, with
the options it was created with (`.gosite.env`, plus the addons in
`cockpit/addons`), using each tag's own `src/main.sh` and a redirected
`GOSITE_HOME`/`GOSITE_WORKSPACE`. Normalise what differs per project - host ports
in `docker-compose.yml`, the `sec-key` fallback in `cockpit/config.php` - and
confirm the old scaffold reproduces the hashes the manifest did record. Then
`git merge-file` project / old / new, file by file.

### "Edited" is often just old

Before resolving a conflict by hand, check whether the project's copy matches a
version gosite shipped - against every commit, not only tags, and comparing code
with comments stripped. On these sites Webapp was byte-identical to an untagged
commit from `main`, Forms' helper to gosite 0.12.0, and aga-growth-dev's cache
retry loop was the code later upstreamed from it. None of that is a local edit.
Take the target version and keep only what matches no release.

When a port of yours is still pending on the project, merge from the commit
before it. Otherwise its adaptations fight the template's native version of the
same feature and bury the real conflicts.

### A merge with zero conflicts can still be wrong

Both sides adding the same thing in different places merges cleanly and
duplicates it. Seen in this rollout, none caught by `git merge-file`:

- two `config()` methods in `Forms.php` - the CMS would not start;
- `ErrNotFound` and `SingletonErr` declared twice in `cms.go`;
- `categoryOf` defined twice in `analytics.js`, which JavaScript accepts;
- `analytics-body` and `consent-link` called twice in a layout - a second
  consent button, and GTM's noscript loaded twice.

After every merge run `php -l` over `cockpit/`, build, count each
`{{template ...}}` call in the layout, and diff the rendered page (below).

### Semantics a clean build hides

- **`content` versus `content.Map()`.** Template helpers that assert
  `map[string]any` fail on the named `cms.Content` type, and every block renders
  its fallback text with no error.
- **`cms.Items` pages at 100.** A caller written for the old client, which
  returned everything, silently counts only the first page.
- **Page discovery registers every file in `pages/`.** An htmx fragment file
  that defines no `content` block becomes a "page" and the boot probe panics.
  Register fragments by their own template names.
- **Mongo-direct projects** (lnequipos-v2) keep their `cms` package. Do not add
  `internal/cms/collection.go` or the reader tests that start a REST server.

### Redis keys under the project prefix are wiped by every purge

The site-wide purge SCANs `<project>:*` and spares only `:stale` keys. Anything
stored there that is not cache goes with it: ba-pow's vote limits ("one vote
per address, ever") and aga-growth-dev's last good financial signals both did.
Look for Redis writes outside `internal/cache` and `internal/seo`; move that
state to a prefix the purge cannot match (`<project>-state:`) and move the
existing keys with `RENAMENX` at startup, which keeps their TTL. Renaming the
constants alone resets the data at deploy.

### QA's REDIS_URL must never use database 1

`cockpit/config.php` pins Cockpit's memory to database 1, keyed by `MONGO_DB` -
production's API key registry is `<project>:app.api.keys` there. A QA page cache
on database 1 of the same server purges `<project>:*` and deletes it. The
template's own QA example currently suggests `/1`; use 2 or higher.

### Forms needs its config block

The Forms addon since 0.43.0 reads `trustedProxies` from the `forms` block of
`cockpit/config.php` and defaults to 0. Behind Traefik that keys the rate
limiter on the proxy's address - every visitor shares one bucket - and every
submission stores the proxy IP. Several projects had no block at all. Copy the
template's.

**Upgrading Forms is data-affecting:** the first time the Forms screen opens,
`ip` and `userAgent` are cleared from submissions older than
`personal_data_retention` (90 days by default). Decide before deploying; set it
to `0` to keep them.

### The stock tests assume the demo site

The template's view tests render with the scaffold's data. A project's layout
that indexes its own keys (`.Chat`, `.Globals`, a typed `.SEO`) fails them on
test data alone. Add the keys, or run the SEO render test on `home` only -
`NewRenderer`'s boot probe already executes every page with the data it needs.
Adapt what they check, never what they protect: check for the GTM fallback, not
for any `<noscript>` a layout carries.

### Prove the new build is the one answering

Diffing before and after proves nothing if the old container is still serving.
Check for something only the new code does - a response header the site did not
send before, or a canary Redis key that only the new purge removes.

---

## → 0.48.0 — the Webapp addon and CMS-driven SEO

The largest migration so far. It removes six addons, adds four routes, and
moves SEO out of page templates and into content.

### 1. Addons: install Webapp, remove the six it absorbs

**This is not optional and the order does not matter, but doing only half of it
breaks the site.** `Webapp` registers the same hooks as the addons it replaces
— `assets.asset.upload`, `app.filestorage.init`, `restApi.config`,
`content.item.save` — so a project carrying both fires every one of them twice:
duplicate REST routes, the asset path fix applied twice, a cache purge for
every purge.

```bash
cp -R <gosite>/src/addons/Webapp <project>/cockpit/addons/Webapp
rm -rf <project>/cockpit/addons/{AssetPathFix,AssetsUpload,CachePurge,CloudStorage,ModelManager,StarterContent}
```

Addons are baked into the CMS image, so this needs a rebuild, not a restart.

### 2. App files

New, no conflict possible:

```
internal/seo/seo.go
internal/seo/seo_test.go
internal/handlers/{robots,llms,favicon,sitemap}.go
```

Refreshed from the template — check the manifest first and only overwrite what
has **no** drift:

```
internal/app/app.go            # wires seo.New + views.WithSEO/WithFavicon/WithRobotsTxt
internal/app/router.go         # the four new routes
internal/handlers/handlers.go  # Deps.SEO, sitemapProviders
internal/cache/cache.go        # adds Get/Set, which internal/seo needs
internal/views/components/seo.html
```

`internal/cache/cache.go` is easy to miss. Without it the build fails with
`s.cache.Get undefined`.

### 3. The three files that usually carry local edits

`internal/views/render.go`, `internal/views/layout.html` and
`internal/blog/blog.go` are the files projects customise. **Merge, never
overwrite.** Use the project's recorded version as the merge base:

```bash
ver=$(grep $'^internal/views/render.go\t' <project>/.gosite/manifest.tsv | cut -f3)
git -C <gosite> show v$ver:src/templates/internal/views/render.go > /tmp/base.go
git -C <gosite> show v0.48.0:src/templates/internal/views/render.go > /tmp/new.go
sed -i '' "s|__MODULE__|$MODULE|g;s|__PROJECT__|$PROJECT|g" /tmp/base.go /tmp/new.go
cp <project>/internal/views/render.go /tmp/merged.go
git merge-file -L project -L "gosite $ver" -L "gosite 0.48.0" /tmp/merged.go /tmp/base.go /tmp/new.go
```

Conflicts seen in practice, both trivial:

- The project already defines `jsonData` — keep its copy, drop the one 0.48.0
  re-introduces.
- Default template data: both sides only **add** keys. Keep every key from both
  (`DarkHero`, `Header`, `Footer` from the project; `Path`, `SEOData` from
  0.48.0).

In `blog.go` the conflict is the article data map: keep the project's keys and
add `"Path": path` and `"SEOData": b.seoData(post)`.

### 4. layout.html — and the language trap

The layout must resolve SEO **before** `<html>`, because the document language
now comes from it:

```gotemplate
{{define "layout"}}
{{$seo := seoData .Path .SEOData}}<!DOCTYPE html>
<html lang="{{or $seo.lang "es"}}">
...
	<title>{{or $seo.title .Title}}</title>
	{{$seo.tags}}
	{{with faviconUrl}}<link rel="icon" href="{{.}}">{{end}}
```

**A `lang` fallback in the template does not protect you.** `seo.lang()`
already substitutes `"en"` when the CMS field is empty, so `$seo.lang` is never
empty and `or` never reaches your fallback. A Spanish site silently becomes
`lang="en"`.

Set the language as content instead, once, before you look at the page:

```bash
docker exec -w /var/www/html <project>-cms php -r '
define("APP_CLI", true); require "bootstrap.php"; $app = Cockpit::instance();
$app->helper("webapp")->ensureModels(true);
$c = $app->module("content"); $i = $c->item("webapp", []) ?: [];
$i["language"] = "es"; $c->saveItem("webapp", $i);'
```

That snippet also creates the `webapp` and `seoPages` models, which otherwise
wait for the first admin page load.

### 5. The seo.html component becomes a no-op

Pages that call `{{template "seo" .Meta}}` from their `head` block keep
compiling and now render nothing — the layout's `$seo.tags` does the work
instead. Update `blog.go` (step 3) **in the same change**, or blog posts lose
their meta tags entirely: the component stops emitting before the new pipeline
starts feeding.

### 6. What stays 404 on purpose

`/sitemap.xml` and `/llms.txt` return 404 until the singleton has a **Site
URL** and an **LLM Text**. Canonical and `og:url` are omitted for the same
reason. None of them falls back to the request host: behind a proxy or on a
preview domain that publishes the wrong origin, which is worse than publishing
nothing.

### 7. Update the manifest by hand

Files brought to the template version get the new hash and `0.48.0`. **Files
merged by hand keep their old hash**, so `sync` keeps seeing them as drifted
and never overwrites the merge. Setting the merged file's current hash would
tell `sync` the file is untouched and hand it the next overwrite.

Drop the six removed addons from the manifest and add the `Webapp` files.

### 8. Content written from the CLI is a draft

`saveItem()` stores `_state: 0` unless you say otherwise, and Cockpit's read
API only ever serves published entries. A `seoPages` row loaded this way is
invisible to the app: the page silently falls back to the site-wide defaults
and shows the home page's title on every route. Set `_state = 1` explicitly:

```php
foreach ($c->items("seoPages", ["limit" => 50]) as $it) { $it["_state"] = 1; $c->saveItem("seoPages", $it); }
```

### 9. Watch for components the project already owns

Copying a component from the templates over one the project wrote is the
easiest way to break a build. On avanxo-dev the project had its own
`components/analytics.html` defining `{{define "analytics"}}` — an event
listener unrelated to the Analytics addon — and every page called it.
Overwriting it with the addon's version (which defines `analytics-head` and
`analytics-body`) turned every page into `no such template "analytics"` at
startup. Check `git show HEAD:<file>` before copying, and when both are needed,
keep both defines in one file.

The same applies to Go: this project's `cms.Client.Singleton` returns
`(Content, error)` rather than `Content`, and its `Cache.Purge` deliberately
keeps stale copies. Adapt the incoming code to the project, not the reverse.

### 10. A project with no manifest

Projects scaffolded before `.gosite/manifest.tsv` existed have no drift signal
at all. `gosite addons list <project>` adopts one from the current files on its
first run, writing nothing else — do that first, but understand what it means:
the baseline is the project *as it is today*, so every local edit is recorded as
if gosite had written it. Find the real base version by diffing candidate tags:

```bash
for t in $(git -C <gosite> tag --sort=-v:refname); do
  n=$(git -C <gosite> show "$t:src/templates/internal/views/render.go" 2>/dev/null \
      | sed -e "s|__MODULE__|$MODULE|g" | diff - <project>/internal/views/render.go | grep -c '^[<>]')
  echo "$t $n"
done | sort -k2 -n | head
```

`gosite addons add` also refuses with a precise list of what the project is
missing — that list is the migration's work order, and it is more reliable than
reading the diff.

## → 0.49.12 — unique service names in production

`docker-compose.prod.yml` used to name its services `app`, `cms`, `mongo` and
`redis`. Coolify deploys stacks onto a **shared predefined network**, so a
second stack - a QA copy beside production, or another project - registers the
same names. DNS then round-robins between them and the application
authenticates against the wrong stack's CMS, which surfaces as
`412 {"error":"Authentication failed"}` on some requests and not others. The
site half works, which is the worst way for this to present.

Every service is now named `<project>-prod-<role>`, and the internal URLs
(`COCKPIT_URL`, `APP_URL`, `REDIS_URL`, `MONGO_HOST`) point at those names.
Apply the same rename to any project deployed this way, and redeploy - the
containers are recreated.

**Local development is deliberately different.** `docker-compose.yml` keeps the
service names `app` and `cms`, because `gosite logs <project> app` passes them
straight to compose, and avoids the collision by setting `container_name` and
naming the container in its internal URLs. Do not make one file match the
other.

## → 0.52.0 — production uses the shared MongoDB and Redis

`docker-compose.prod.yml` no longer defines `<project>-prod-mongo` and
`<project>-prod-redis`, and the `mongo-data` and `redis-data` volumes are gone
with them. `MONGO_HOST`, `REDIS_URL` and `COCKPIT_MEMORY_SERVER` come from the
environment instead.

**Check what the project actually deployed before changing anything.** Most
projects never used the self-hosted stack - they were edited to point at shared
servers long ago, and for those this is a no-op:

```bash
grep -nE 'prod-mongo|prod-redis|mongo-data|redis-data' <project>/docker-compose.prod.yml
```

No output means the project is already on shared services. Take the new
template's wording if you like, but nothing has to move.

If it does print something, the deployed stack is holding live data in its own
volumes, and **the compose change alone deletes access to it**. Dump and restore
before you redeploy, not after:

```bash
docker exec <stack>-prod-mongo mongodump --archive > prod.archive
mongorestore --uri "mongodb://<user>:<pass>@<shared-host>:27017" \
  --archive < prod.archive --nsFrom '<olddb>.*' --nsTo '<newdb>.*'
```

Redis needs nothing carried over - it holds only the rendered page cache, which
rebuilds on the first request - but the new `REDIS_URL` **must** use a database
index no other environment uses. The cache keys are compiled in and carry the
project name, never the environment, so production and QA on one index serve
each other's HTML.

Set `MONGO_DB` per environment for the same reason, and one more:
`cockpit/config.php` uses it as the key prefix for Cockpit's app memory, which
holds the API key registry the `/api/*` gate reads. Two environments sharing it
means rotating one's `COCKPIT_API_TOKEN` silently breaks the other.

## → 0.53.0 — cookie consent gates the analytics tags

Only projects with the `Analytics` addon are affected. For everything else this
release changes nothing.

**Read this first: after the upgrade the site tracks nobody until you configure
the banner.** That is the intended behaviour, not a regression. The tags shipped
in 0.46.0 loaded unconditionally; they now load only for a visitor who agreed to
their category, and with no banner there is nothing to agree to.

### 1. The application half

Four new files, none of which can conflict:

```bash
G=<gosite> ; P=<project>
MODULE=$(head -1 $P/go.mod | cut -d" " -f2)

cp $G/src/templates/static/js/analytics/consent.js       $P/static/js/analytics/
mkdir -p $P/static/css
cp $G/src/templates/static/css/consent.css               $P/static/css/
cp $G/src/templates/internal/analytics/consent.go        $P/internal/analytics/
cp $G/src/templates/flavors/<flavor>/internal/views/components/consent.html \
   $P/internal/views/components/

sed -i "" "s|__MODULE__|$MODULE|g" $P/internal/analytics/consent.go
```

`<flavor>` is `tailwind` or `plain`; the two consent components are identical
today, but take the one matching the project so a later divergence lands
correctly.

**Do not skip the `sed`.** `consent.go` ships with the `__MODULE__` placeholder
and the build fails on it - which is the good outcome. The silent version of
this mistake is forgetting the file entirely: the project still compiles, still
serves pages, and has no gate.

Then three edited files. `internal/analytics/analytics.go` gains the `Category`
passthrough, `internal/views/render.go` gains the `Consent` type, the
`WithConsent` option and the `consentSettings` function, and
`internal/handlers/purge.go` gains `analyticsConsent` to `siteWideModels`.
`render.go` is one of the files projects customise, so merge it against the
project's recorded version the way section 3 of the 0.48.0 migration describes.

`internal/views/layout.html` and `internal/views/components/analytics.html` are
also customised in most projects, so merge rather than overwrite. Two things
must be true in the merged layout:

- `{{template "consent-head" .}}` appears **before**
  `{{template "analytics-head" .}}`. The gate reads its cookie synchronously,
  and loading it second leaves a window where the banner flashes at a visitor
  who already decided.
- `{{template "consent-link" .}}` appears somewhere in the body, or the site's
  own footer carries an element with `data-consent-open`. Without one of the
  two, a visitor cannot withdraw, and withdrawing has to be as easy as
  consenting.

`internal/app/app.go` gains one line, `views.WithConsent(...)`, next to
`views.WithIntegrations(...)`. A project that has customised `app.go` keeps
compiling without it — and silently has no banner, so check for it rather than
trusting the build.

### 2. The CMS half

Replace the addon directory and rebuild the image - addons are baked in, so a
restart is not enough:

```bash
rm -rf $P/cockpit/addons/Analytics
cp -R $G/src/addons/Analytics $P/cockpit/addons/Analytics
gosite stop <project> && gosite start <project>   # rebuilds both images
```

Then open the admin once. `ensureModels()` creates `analyticsConsent` and adds
the consent `category` field to the existing `analyticsIntegrations` model. Both
are visible on the **Analytics** screen, which now leads with the consent state.

### 3. Configure it, or the site stays silent

**Analytics → Set up the banner.** The singleton arrives already filled in, in
Spanish, and switched off, so the minimum is to tick **Ask for consent**. Read
the wording first and adjust it to the site's voice.

Two fields are deliberately left empty and both are worth a moment:

- **the privacy policy link.** Nothing can invent it, and with it empty no link
  is shown — which most regulators expect you to have.
- **`copyVersion`** is seeded with the date the singleton was created. It is
  stored with each visitor's choice so you can tell later which wording they
  agreed to. Change it when the meaning of the text changes, not for a typo; it
  does not re-ask anybody.

Then look at the **Needs consent** column. Google Tag Manager defaults to
`marketing`, which is the safer reading rather than a fact about your container.
If yours holds analytics tags only, set that entry's `category` to `analytics`
so the banner asks for less.

### 4. Verify

The body-identical rule below does **not** hold for this upgrade, and that is
the one exception in this file. Enabling consent adds a stylesheet, a JSON block
and a script to the head, and the reopen control to the body. What to check
instead, with the network panel open on a fresh profile:

1. Before touching the banner, **no request to any provider or provider CDN**.
   Not a deferred one, none. This is the whole guarantee.
2. Accept, and the provider's own requests appear.
3. Reload. No banner, and tracking resumes immediately.
4. Reopen the preferences, refuse, and confirm the page reloads and the requests
   stop.

A script tag being present proves nothing here, exactly as it proved nothing in
0.46.0.

## → 0.53.1 — Coolify domains, the MinIO image, QA's Redis database

**Production and QA composes.** If a project took the 0.51.0 compose, check
both Traefik rules and the app's environment:

```bash
grep -nE 'SERVICE_FQDN_(APP|CMS):\?|^\s+- SERVICE_FQDN_' <project>/docker-compose.prod.yml <project>/docker-compose.qa.yml
```

Any match has to go: make the rule a bare `Host(`${SERVICE_FQDN_APP}`)` and
delete the `- SERVICE_FQDN_APP` line. Coolify only recognises its magic
variables in that exact form, so the domain does not resolve otherwise.

**QA.** `REDIS_URL` must not use database 1. See "QA's REDIS_URL must never use
database 1" above.

**Local infra.** Nothing to do in projects. Run `gosite infra up` once; it
recreates MinIO on `coollabsio/minio` with the same volume and credentials.

---

### Verify before you call it done

Capture the site **before** touching it, then diff:

```bash
curl -sS https://<site>/ > before.html   # and the blog index, and one article
# ... upgrade ...
diff <(sed -n '/<body/,/<\/body>/p' before.html) <(sed -n '/<body/,/<\/body>/p' after.html)
```

The body must be **byte-identical**. The head must only gain tags. Compare
the body ignoring blank lines - template comments and `{{if}}` guards leave
whitespace that does not render. On aga-growth-dev this caught three regressions that the build and the test
suite did not: `lang="es"` becoming `en`, blog posts losing `og:type="article"`,
and `og:image` built without a separator. On avanxo-dev it caught two more: a
`robots.txt` that lost its `Sitemap:` line, and every solution page serving the
home page's title because the `seoPages` rows were still drafts.

A project that already has hand-written SEO needs its values **moved into the
CMS**, not just the pipeline swapped underneath them. Read the titles,
descriptions and canonicals out of the Go registry, write them to `seoPages`,
publish them, and only then compare.

In the 0.53.0 rollout the body diff caught the duplicated consent button on
aga-growth-dev, which the build, `go vet` and every test package passed.
