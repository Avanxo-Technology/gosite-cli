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

### Verify before you call it done

Capture the site **before** touching it, then diff:

```bash
curl -sS https://<site>/ > before.html   # and the blog index, and one article
# ... upgrade ...
diff <(sed -n '/<body/,/<\/body>/p' before.html) <(sed -n '/<body/,/<\/body>/p' after.html)
```

The body must be **byte-identical**. The head must only gain tags. On
aga-growth-dev this caught three regressions that the build and the test suite
did not: `lang="es"` becoming `en`, blog posts losing `og:type="article"`, and
`og:image` built without a separator.
