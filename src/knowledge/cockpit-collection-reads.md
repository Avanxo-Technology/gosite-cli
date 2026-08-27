# Cockpit core — collection reads, field types and authorship

Verified against Cockpit core **2.14.0** by reading `modules/Content/api.php`,
`modules/Content/bootstrap.php` and the field component registrations. Re-check
after a Cockpit upgrade.

## `GET /api/content/items/{model}`

Parameters, all read in `modules/Content/api.php` (~line 468):

| param | type | notes |
| --- | --- | --- |
| `limit` | int | |
| `skip` | int | |
| `populate` | int | **depth**, not a boolean; also injects the calling user into the process context |
| `filter` | string | **JSON5 string**, decoded server-side — not nested query params |
| `sort` | string | JSON5 string |
| `fields` | string | JSON5 string; projection |
| `locale` | string | defaults to `default` |

### The response shape depends on the parameters

```php
if (isset($options['skip'], $options['limit'])) {
    return ['data' => $items, 'meta' => ['total' => $content->count($model, $filter)]];
}
return $items;
```

- **both** `skip` and `limit` present → `{data, meta}`
- otherwise → a bare array

`meta.total` is a real count of everything matching the filter, not the size of
the page. So paging can show an exact page count — but only if both parameters
are sent. Sending them always is the simplest way to make the shape
deterministic.

Reading the wrapper as if it were the list yields two "items" with no `_id`,
which silently defeats every id comparison downstream (this bit `Replica`).

### Published-only is forced, not requested

```php
$options['filter']['_state'] = 1;
```

Applied *after* the client's filter is decoded, so a client-supplied `_state`
is overwritten. Unpublished entries cannot be read through the core API at all
— which makes drafts fail-safe, and makes draft preview impossible without an
addon exposing its own endpoint.

New items default to `_state = 0` (`bootstrap.php`), i.e. unpublished. Anything
written programmatically that should be live must set `_state = 1` explicitly.

## Authorship: `_cby` and `_mby`, not `_by`

`Content` stamps the acting user on every save:

```php
$item['_modified'] = $time;
$item['_mby'] = $context['user']['_id'] ?? null;

if (!$isUpdate) {
    $item['_created'] = $time;
    $item['_state']   = $item['_state'] ?? 0;
    $item['_cby']     = $context['user']['_id'] ?? null;
}
```

- `_cby` — who created it
- `_mby` — who last modified it

Both hold a **user id**, so rendering a name means resolving it against the
users collection. Passing `['user' => null]` as the save context suppresses the
stamp, which is what `Forms` does for anonymous public submissions.

## Field types

Registered components, from `VueView.component('field-<type>', ...)`. The type
is the registered name, which is **not always the filename** — the richtext
component registers as `wysiwyg`:

```
boolean  code   color  date   datetime  nav      number  object
select   set    table  tags   text      time     wysiwyg
asset            (Assets module)
contentItemLink  (Content module)
```

### Relations: `contentItemLink`

```php
[
    'name'     => 'blog',
    'type'     => 'contentItemLink',
    'multiple' => false,
    'opts'     => [
        'link'    => 'blogs',   // target model name (required)
        'display' => 'title',   // field shown in the admin
        'filter'  => [],        // optional, restricts what can be picked
    ],
]
```

Stored value is a reference, not the document:

```json
{"_model": "blogs", "_id": "..."}
```

`multiple: true` stores an array of those. Resolving them into real documents in
an API response requires `populate` with a depth.

## Uniqueness is per-model and global, never scoped

A model can declare `meta.unique`, enforced on save by
`Content\Helper\Content::isContentUnique()`, which throws
`AppNotification "::<field>:: must be unique"`.

**It cannot express "unique within a group".** The check builds

```php
$this->app->dataStorage->findOne($collection, ['$or' => $filter], $projection);
```

— an `$or` across the whole collection, one clause per declared field, with no
scoping by any other field. So `meta.unique = 'slug'` means *globally unique
across the model*, not unique per parent.

Scoped uniqueness (e.g. a slug unique within its blog) has to be implemented in
an addon on `content.item.save.before.{model}`.
