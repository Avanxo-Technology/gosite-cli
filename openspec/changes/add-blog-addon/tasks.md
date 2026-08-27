## 1. Spike — resolve the unverified Cockpit behaviours

Nothing below can be written correctly until these land. Run against a real
Cockpit (ba-pow's is on the current baseline) and record the findings in
`src/knowledge/` so they outlive this change.

- [x] 1.1 Determine how Cockpit v2 declares a relation field in `createModel()` — the field `type`, and the `opts` shape naming the target model and whether it is single or multiple
- [x] 1.2 Determine whether `GET /api/content/items/{model}` returns `_by`, and whether `populate` resolves relation fields into nested objects or leaves ids
- [x] 1.3 Determine what `meta` contains when `skip` and `limit` are both sent (total? page count? neither?)
- [x] 1.4 Determine whether echo v5 prefers a static route segment over `:param` at the same depth — the `/{blog}` URL choice depends on it
- [x] 1.5 Write the findings to `src/knowledge/cockpit-collection-reads.md`, following the style of the existing knowledge files
- [x] 1.6 Record the spike's corrections in `design.md` — 1.4 passed, so no route-per-blog fallback is needed; authorship is `_cby`/`_mby`, not `_by`

## 2. The Cockpit addon — models

- [x] 2.1 Create `src/addons/Blog/` with `bootstrap.php`, registering the helper and the admin init hook, mirroring `src/addons/Forms/bootstrap.php`
- [x] 2.2 Implement `ensureModels()` creating `blogs`, `blogPosts`, `blogCategories` and `blogAuthors` with `'group' => 'Blog'`, skipping any model that already exists
- [x] 2.3 Declare the relation fields on `blogPosts` (blog, category, author) using the field shape found in 1.1
- [x] 2.4 Add the `blog/manage` permission to `app.permissions.collect` and the sidebar entry under Modules, with an icon asset
- [x] 2.5 Verify against a real Cockpit that a fresh install creates all four models and that re-running leaves an existing `blogPosts` untouched

## 3. The Cockpit addon — slugs, authors and validation

- [x] 3.1 Derive a slug from the title when the slug field is empty, transliterating accents to ASCII and lowercasing
- [x] 3.2 Enforce slug uniqueness within a blog on `content.item.save.before.blogPosts` — core's `meta.unique` is global per model and cannot scope by blog, so it must not be used here
- [x] 3.3 Refuse blog slugs that collide with the scaffold's reserved paths (`static`, `storage`, `healthz`, `cache`, `api`)
- [x] 3.4 Resolve the byline: use the `blogAuthors` reference, falling back to the `blogAuthors` item linked to `_cby`, and render nothing when neither resolves
- [x] 3.5 Ensure no Cockpit user account field beyond display data — never the e-mail — can reach a public response through the byline fallback
- [x] 3.6 Verify each rule by executing: duplicate slug in the same blog refused, same slug in two blogs accepted, reserved slug refused, accented title transliterated

## 4. The Cockpit addon — admin screen

- [x] 4.1 Add the `/blog` admin controller and view listing articles with their publication state, gated on `blog/manage`
- [x] 4.2 Build preview links to the article's real public URL, and degrade to a stated "preview unavailable" when the project's base URL is not configured
- [x] 4.3 Add per-article cache purge from the screen, reusing the project's existing authenticated purge endpoint
- [x] 4.4 Verify a user without `blog/manage` is refused and receives no article data
- [x] 4.5 Write `src/addons/Blog/README.md` covering the models, the slug rules, the byline fallback, and the fact that editing a published slug orphans existing links

## 5. Go — collection reads

- [x] 5.1 Add a collection read to `internal/cms` taking model, filter, sort, page size, page and populate depth
- [x] 5.2 Always send `skip` and `limit`, and decode both the bare-array and `{data, meta}` shapes into one result type carrying items and a total
- [x] 5.3 Report whether a next page exists even when no total is available, using the `limit + 1` fallback if 1.3 showed `meta` carries no total
- [x] 5.4 Return an error distinguishable from an empty result when the read fails, so a failed render is discarded rather than cached
- [x] 5.5 Add tests covering both response shapes, the wrapper-read-as-list trap, empty results and a failed read

## 6. Go — cache group purge

- [x] 6.1 Add group purge to `internal/cache`, clearing both fresh and stale copies of every key in the group
- [x] 6.2 Keep the purge off the hot path and avoid blocking the server while scanning the keyspace
- [x] 6.3 Extend the purge handler to invalidate an article's key plus every index key of its blog, leaving other blogs and the home page cached
- [x] 6.4 Confirm the purge endpoint's authentication and fail-closed behaviour are unchanged from v0.43.0 — no missing token treated as "no auth required"
- [x] 6.5 Add tests: group purge clears the group, leaves unrelated keys, succeeds on an empty group, and reports a backend failure

## 7. Go — blog pages

- [x] 7.1 Create `internal/blog` owning the handlers, cache keys and a single mount function
- [x] 7.2 Implement the blog index at `/{blog}`: newest first, paginated, 404 for an unknown blog and for a page past the end
- [x] 7.3 Implement the article page at `/{blog}/{slug}`: 404 for an unknown or unpublished article, resolving the byline, category and cover image
- [x] 7.4 Serve both through the existing cache-aside path, discarding failed renders and bypassing the cache in development
- [x] 7.5 Emit per-page title, meta description, Open Graph tags and a canonical URL, handling an article with no cover image
- [x] 7.6 Add the mount line to `src/templates/internal/app/router.go`, positioned so concrete routes keep precedence
- [x] 7.7 Verify `/healthz`, `/cache/purge`, `/static/...` and the home page behave exactly as before, and that a project page at `/contacto` wins over a blog with that slug

## 8. Templates — both flavors

- [x] 8.1 Add index and article page templates to `src/templates/flavors/tailwind/internal/views/pages/`
- [x] 8.2 Add the same two pages to `src/templates/flavors/plain/`, styled with the flavor's stylesheet and no Tailwind classes
- [x] 8.3 Confirm `render.go`'s `//go:embed pages/*.html` picks both up with no registration change
- [x] 8.4 Render both flavors end to end against a real CMS and check the pages, the pager and the metadata

## 9. Distribution and install

- [x] 9.1 Offer `Blog` in the addon prompt in `cmd_create.sh` and include it in `--addons`
- [x] 9.2 Copy the Go blog package and page templates as part of installing the addon, tracked in the sync manifest like other managed files
- [x] 9.3 Wire the blog from `internal/app/router_blog.go` instead of patching `router.go` — the install never rewrites a file the project owns, so there is no insert to fail
- [x] 9.4 Make the install idempotent — no duplicated mount line, no duplicated content on a second run
- [x] 9.5 Preserve and report hand-edited blog templates, consistent with how sync already treats them
- [x] 9.6 Confirm the install touches nothing else: compose files, `.env` and other addons unchanged
- [x] 9.7 State at the end of the install that both the CMS image and the application must be rebuilt, not restarted

## 10. Verify end to end

- [x] 10.1 Create a throwaway scaffold with the Blog addon and confirm the blog works with no manual step
- [x] 10.2 Install into a copy of an existing project and confirm both halves land without overwriting owned files
- [x] 10.3 Walk the scenarios in all five spec files against the running sandbox, not by reading the code
- [x] 10.4 Confirm a draft article is unreachable at its URL and absent from the index

## 11. Ship

- [x] 11.1 Bump `src/VERSION`
- [x] 11.2 Update `docs/index.html` and `README.md` for the new addon and any command surface change
- [x] 11.3 Update the generated `MEMORY.md` / `ARCHITECTURE.md` templates for the new scaffold paths
- [x] 11.4 Add a CHANGELOG entry stating the CMS-image rebuild requirement
- [ ] 11.5 Tag the release and publish it with both assets — a push alone is not installable
- [ ] 11.6 Roll out to ba-pow first, verify, and leave the four unmigrated projects for a separate pass
