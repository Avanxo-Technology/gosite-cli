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

## Caveat — container rebuilds

The modification lives **inside** the Cockpit Docker image (`cockpithq/cockpit:core-*`),
not on a host-mounted volume. If the container is rebuilt from the upstream image,
the change is lost and must be re-applied.

To re-apply after rebuild:

```bash
docker exec <cms-container> bash -c "cat >> /var/www/html/modules/Assets/api.php << 'PHP'

    \$restApi->addEndPoint('/assets/upload', [
        'POST' => function(\$params, \$app) {
            \$meta = ['folder' => \$this->param('folder', '')];
            return \$this->module('assets')->upload('files', \$meta);
        }
    ]);
PHP"
```

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

1. That the custom `/api/assets/upload` endpoint exists
2. How to upload assets via the API (curl command)
3. That the change must be re-applied if the CMS container is rebuilt

And in `MEMORY.md` under "Common tasks":

```
| Upload assets via API | `POST /api/assets/upload` with `files[]` multipart; returns `{"assets":[{"path":"...","_id":"..."}]}` |
```