# Cockpit CMS — Asset Upload REST API

## Default behaviour

Cockpit's core REST API (registered via `restApi.config` in each module's `api.php`)
only exposes **GET** endpoints for assets. There is no built-in endpoint for uploading
files through the REST API.

## Adding the endpoint

In any module's `api.php` (typically `modules/Assets/api.php`), inside the callback:

```php
$this->on('restApi.config', function($restApi) {

    // ... existing endpoints ...

    $restApi->addEndPoint('/assets/upload', [
        'POST' => function($params, $app) {
            $meta = ['folder' => $this->param('folder', '')];
            return $this->module('assets')->upload('files', $meta);
        }
    ]);
});
```

This registers `POST /api/assets/upload`.

## gosite — built-in addon

Every project scaffolded with `gosite create` includes this endpoint automatically
as a Cockpit addon at `cockpit/addons/AssetsUpload/bootstrap.php`. No manual
Docker exec or api.php editing is needed — the addon is bind-mounted in dev and
baked into the production image by `Dockerfile.cms`.

## Usage

```bash
curl -X POST \
  -H "api-key: $COCKPIT_API_TOKEN" \
  -F "files[]=@image.jpg" \
  "https://cms.PROJECT.test/api/assets/upload"
```

Returns:
```json
{"assets":[{"path":"/2026/08/08/filename_uid_xxxxx.jpg","_id":"6a..."}]}
```

## Caveat — manual projects only

Projects that were NOT scaffolded with `gosite create` (or were created before
this addon was added) do not have the endpoint. For those, add it manually as
a Cockpit addon at `cockpit/addons/AssetsUpload/bootstrap.php` (see the PHP
code above). Once the file is in place, restart the CMS container so Cockpit
discovers the new addon.

## Asset field type

When a Cockpit collection field is of type `asset`, the CMS stores the value as an
object, not a plain string:

```json
{
  "path": "/2026/08/08/filename.jpg",
  "_id": "6a..."
}
```

The consuming application must handle **both** formats (legacy string and asset
object) for backward compatibility. The recommended approach is a custom
`UnmarshalJSON` that tries the object format first and falls back to the string.

## Project documentation checklist

Every gosite project that uses this endpoint should document in its `ARCHITECTURE.md`:

1. That `POST /api/assets/upload` exists (via the built-in `AssetsUpload` addon)
2. How to upload assets via the API (curl command)

And in `MEMORY.md` under "Common tasks":

```
| Upload assets via API | `POST /api/assets/upload` with `files[]` multipart; returns `{"assets":[{"path":"...","_id":"..."}]}` |
```

## Replica addon — asset sync

When using the Replica addon to replicate content between Cockpit instances, the
asset field values (`{path, _id}`) travel with the content items. For the
references to resolve on the destination, the asset metadata (`assets`
collection) and files must also be replicated.

The target's `syncAssets` setting controls this:

| `syncAssets` | Asset metadata | Asset files | Field references work? |
|---|---|---|---|
| `true` (default) | Replicated with same `_id` | Replicated to `uploads://` | Yes |
| `false` | Not replicated | Not replicated | No — `_id` points to nothing |

**Since v1.0.0, `syncAssets` defaults to `true`** in both the admin UI (checkbox
checked by default) and the backend constructor. CLI targets require the
explicit `--sync-assets` flag (opt-in).

Asset replication requires both instances to run the Replica addon (peer
transport). If the remote is a plain Cockpit instance, assets are skipped with a
log message and field references on the remote will be broken.