# Cockpit CMS — Model Manager REST API

## Default behaviour

Cockpit's core REST API exposes `GET /api/content/items/{collection}` and
`POST /api/content/items/{collection}` for reading and writing collection data,
but there is no built-in endpoint for managing **model definitions** (schemas)
themselves — creating, updating, listing, or removing collections and singletons
programmatically.

## The `ModelManager` addon

Every gosite project ships this as a built-in addon at
`cockpit/addons/ModelManager/bootstrap.php`. It registers three endpoints under
the REST API:

### List all models

```
GET /api/models
```

Returns every model definition (collections, singletons, trees) with their
fields, labels, and metadata.

### Save (create or update) a model

```
POST /api/models/save
```

Body: `model` parameter with `name`, `type` (`collection`|`singleton`|`tree`),
and `fields` array.

### Remove a model

```
POST /api/models/remove
```

Body: `name` parameter with the model name.

## Usage

```bash
# List all models
curl -H "api-key: $COCKPIT_API_TOKEN" \
  "https://cms.PROJECT.test/api/models"

# Create a collection
curl -X POST \
  -H "api-key: $COCKPIT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":{"name":"articles","type":"collection","fields":[{"name":"title","type":"text","label":"Title"}]}}' \
  "https://cms.PROJECT.test/api/models/save"

# Remove a model
curl -X POST \
  -H "api-key: $COCKPIT_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"articles"}' \
  "https://cms.PROJECT.test/api/models/remove"
```

## Authentication

The addon respects Cockpit's ACL:
- **Listing** filters out models the user cannot read
- **Saving** requires `content/{model}/manage` or `content/:models/manage`
- **Removing** requires `content/:models/manage`

## Project documentation checklist

In `MEMORY.md` under "Common tasks":

```
| Manage content models via API | `GET /api/models`, `POST /api/models/save`, `POST /api/models/remove` |
```