# Blog

Shared blog structure for gosite sites, on Cockpit v2 (core-2.14.0).

Articles are ordinary Content collections, so authoring happens in Cockpit's own
editor like any other content. This addon adds what the core cannot: the model
set every gosite site shares, slug rules, a byline that falls back to the
editing user, and an admin screen that links into the real public site.

The pages themselves are served by the Go application at `/{blog}` and
`/{blog}/{slug}`. This addon serves nothing to visitors.

## Models

Created automatically the first time somebody opens the admin. A model that
already exists is left completely alone, fields included.

| model | fields |
| --- | --- |
| `blogs` | title, slug, description |
| `blogPosts` | title, slug, blog, excerpt, body, cover, category, author, publishedAt |
| `blogCategories` | title, slug |
| `blogAuthors` | name, bio, photo, user |

All four are grouped under **Blog** in the Content sidebar.

### Why the names are prefixed

`categories` and `authors` are names a project is likely to want for its own
content. Because installation skips a model that already exists, a collision
would be **silent**: the addon would find `categories`, leave it alone, and the
blog would quietly start reading product categories. Hence `blogCategories`.

### Multi-blog is data, not schema

A blog is an item in `blogs`; an article references it. Adding a second blog
never means adding a model, so every gosite project runs the same four models
and a fix here is a fix everywhere.

## URLs and slugs

```
/noticias              the blog index
/noticias/mi-post      an article
/casos/mi-post         a different article; the same slug is fine
```

Slugs are derived from the title when left empty, transliterated to ASCII and
lowercased — `Diseño Gráfico` becomes `diseno-grafico`.

An article's slug must be unique **within its blog**. Cockpit's own
`meta.unique` cannot express that: `isContentUnique()` runs an `$or` across the
whole collection with no scoping, so it would force slugs to be unique globally
and break the URL scheme. The scoped check therefore lives in this addon, on
`content.item.save.before.blogPosts`.

A blog's slug must be unique across blogs and must not be one of the paths the
scaffold already serves — `static`, `storage`, `healthz`, `cache`, `api`,
`admin`. A blog sits at the root of the site, so one of those would be
unreachable: the router resolves a concrete path before `/{blog}`.

> **Changing a published slug orphans every existing link to it.** The addon
> does not keep a redirect map. Treat a published slug as permanent.

## Drafts

Nothing to configure. Cockpit's core read API hard-codes `filter._state = 1`, so
an unpublished article is invisible to the site — not filtered out by the app,
but never served by the CMS in the first place. New items default to
unpublished.

The consequence is that **previewing a draft on the site is not possible**. The
admin screen links to published articles only.

## Bylines

The `author` reference wins. When it is empty the byline falls back to the
`blogAuthors` entry whose `user` field holds the id of the Cockpit account that
created the article (`_cby`).

So somebody writing their own blog never has to pick an author, while an agency
publishing on behalf of a client still can. Guest authors work too — they need
a `blogAuthors` entry, not a Cockpit account.

Only display fields (`name`, `bio`, `photo`) ever leave the addon. Cockpit
accounts are staff accounts and carry e-mail addresses; those are never exposed.

## Admin screen

`GET /blog`, gated on the `blog/manage` permission (Settings > Roles). Lists
articles with their publication state, byline, and a link to the article's real
address on the public site.

That preview link needs the site's public base URL. Set `SITE_URL` in the
project environment, or `blog.site_url` in `cockpit/config.php`:

```php
'blog' => [
    'site_url' => 'https://example.com',
],
```

Note the key sits at the **root** of the config array, not under `config/` —
`bootstrap.php` builds the app with `new Lime\App($config)`, so top-level keys
land at the root of the registry. Getting this wrong left the entire Forms
config block inert for several releases.

Without it the screen still lists everything and says preview links are
unavailable, rather than emitting broken links.

Each row also offers a manual cache purge. Saving an article already purges
automatically through the `CachePurge` addon; the button is for when the site
and the CMS have drifted apart anyway.

## Admin API

Admin-only, `blog/manage`, CSRF on mutations.

```
GET  /blog/api/posts?blog=<id>
POST /blog/api/purge         { "model": "blogPosts", "id": "..." }
```

There is no public read surface. The site reads content through Cockpit's core
REST API.

## Installing

The addon is baked into the CMS image (`Dockerfile.cms COPY`), so an existing
project needs a **CMS rebuild**, not a restart.
