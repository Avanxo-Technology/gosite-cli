# Medusa Admin API: loading a catalogue by script or AI

Every call below was run against `gosite-medusa:0.55.1` (Medusa 2.21.2), uploads against 0.56.0, on a
fresh store seeded by the image. The Admin UI at `https://shop.<domain>/app`
does the same through the same API; use this when products are created in
bulk, by a script, or by an AI agent.

## Where to call it

| Environment | Base URL |
| ----------- | -------- |
| dev | `https://shop.<domain>` (only if the site routes it; aldu-dev does in its override) or `docker exec <project>-medusa` + `http://localhost:9000` |
| QA / prod | `https://shop.<domain>` (`SERVICE_FQDN_SHOP` in Coolify, since 0.56.0; only `/app`, `/admin`, `/auth`, `/hooks` are routed) |

Never call `/admin/*` from the Go site: it reads the Store API with the
publishable key, nothing else.

## Authentication: a Secret API Key, sent as Basic auth

Create it once per store and environment in the Admin UI: **Settings → Secret
API Keys → Create**. The token (`sk_…`) is shown **only at creation**; a later
listing returns it empty. Keep it in the site's `.env` (never committed), e.g.
`MEDUSA_ADMIN_API_KEY`, and revoke it in the same screen when it leaks.

```bash
curl -u "$MEDUSA_ADMIN_API_KEY:" https://shop.<domain>/admin/products
```

The key is the **username of Basic auth, with an empty password** (note the
trailing `:`). `Authorization: Bearer sk_…` answers **401**.

Scripted alternative (no UI): log in as the admin and create the key.

```bash
jwt=$(curl -s -X POST $B/auth/user/emailpass -H 'content-type: application/json' \
  -d '{"email":"<admin>","password":"<password>"}' | jq -r .token)
curl -s -X POST $B/admin/api-keys -H "authorization: Bearer $jwt" \
  -H 'content-type: application/json' -d '{"title":"AI catalogue","type":"secret"}' \
  | jq -r .api_key.token
```

## The ids a product needs

The gosite seed creates everything; look the ids up, never hardcode them
(each store and environment has its own).

```bash
A=(-s -u "$MEDUSA_ADMIN_API_KEY:" -H 'content-type: application/json')
SC=$(curl "${A[@]}" "$B/admin/sales-channels?name=gosite" | jq -r '.sales_channels[0].id')
SP=$(curl "${A[@]}" "$B/admin/shipping-profiles" | jq -r '.shipping_profiles[0].id')
LOC=$(curl "${A[@]}" "$B/admin/stock-locations" | jq -r '.stock_locations[0].id')
```

**The sales channel must be `gosite`.** Medusa also creates a "Default Sales
Channel"; the site's publishable key sees only `gosite`, so a product in the
default channel (or in none) exists in the Admin and never appears in the
store.

## Create a category

```bash
curl "${A[@]}" -X POST $B/admin/product-categories \
  -d '{"name":"Chaquetas","handle":"chaquetas","is_active":true,"is_internal":false}'
```

`parent_category_id` nests it. The storefront filters by `?category=<handle>`.

## Create a product with variants

```json
{
  "title": "Chaqueta Industrial",
  "handle": "chaqueta-industrial",
  "description": "Chaqueta de dotación en drill.",
  "status": "published",
  "shipping_profile_id": "<SP>",
  "sales_channels": [{"id": "<SC>"}],
  "categories": [{"id": "<category id>"}],
  "thumbnail": "<image URL>",
  "images": [{"url": "<image URL>"}],
  "options": [
    {"title": "Talla", "values": ["S", "M", "L"]},
    {"title": "Color", "values": ["Azul"]}
  ],
  "variants": [
    {"title": "S / Azul", "sku": "CHQ-IND-S-AZ", "manage_inventory": true,
     "options": {"Talla": "S", "Color": "Azul"},
     "prices": [{"amount": 159900, "currency_code": "cop"}]}
  ]
}
```

```bash
curl "${A[@]}" -X POST $B/admin/products -d @product.json
```

- **Amounts are in the major unit**: `159900` is $159.900 COP, `19.99` is
  US$19.99. Never multiply by 100. The currency is the region's (`cop` for
  `commerce_region: co`, `usd` for `us`).
- Every variant names a value for **every** option, by option title.
- `status: "draft"` hides the product from the store (the Store API returns
  nothing for it); publish it with `{"status":"published"}`.
- A product with no options still needs one: the seed's demo uses
  `{"title":"Default","values":["Default"]}`.

## Idempotency: look up by handle first

The handle is the key. Creating a duplicate fails with
`invalid_data: Product with handle: …, already exists.` so an agent re-running
a load should search first and update instead:

```bash
curl "${A[@]}" "$B/admin/products?handle=chaqueta-industrial&fields=id,handle"   # count 0 or 1
curl "${A[@]}" -X POST $B/admin/products/<id> -d '{"title":"…","description":"…"}'
```

Updates are `POST` on the resource (there is no `PATCH`).

## Prices

```bash
curl "${A[@]}" -X POST "$B/admin/products/<id>/variants/<variant id>" \
  -d '{"prices":[{"amount":149900,"currency_code":"cop"}]}'
```

The `prices` array **replaces** the variant's prices: send every currency it
should keep.

## Stock

`manage_inventory: true` creates one inventory item per variant, but with **no
level at any location**, so the store sees `inventory_quantity: 0` (sold out)
until stock is set at the seed's location:

```bash
curl "${A[@]}" "$B/admin/products/<id>/variants?fields=sku,*inventory_items" \
  | jq -c --arg loc "$LOC" '{create: [.variants[] | {inventory_item_id: .inventory_items[0].inventory_item_id,
        location_id: $loc, stocked_quantity: 25}]}' > levels.json
curl "${A[@]}" -X POST $B/admin/inventory-items/location-levels/batch -d @levels.json
```

To change an existing level:

```bash
curl "${A[@]}" -X POST "$B/admin/inventory-items/<iitem id>/location-levels/$LOC" \
  -d '{"stocked_quantity":30}'
```

`manage_inventory: false` sells without limit (the store reports no quantity).

## Images

Since gosite 0.56.0 Medusa stores uploads in the site's bucket (the same
`S3_*` variables as the CMS, folder `medusa/` under `S3_PREFIX`), so both work:

- **Upload**, then use the returned URL:
  ```bash
  curl -s -u "$MEDUSA_ADMIN_API_KEY:" -X POST $B/admin/uploads -F "files=@chaqueta.jpg"
  # {"files":[{"id":"medusa/chaqueta-01M….jpg","url":"<S3_PUBLIC_URL>/medusa/chaqueta-01M….jpg"}]}
  ```
- **Any public URL** in `thumbnail` and `images[].url` (Medusa does not copy it).

An upload URL that starts with `http://localhost:9000/static/` means the store
runs without S3 (`STORAGE_ADAPTER` is not `s3`, or a key is missing): the file
is inside the container and disappears on the next deploy. Fix the
environment before loading images.

When copying a catalogue between environments, an uploaded image's URL points
at the source environment's bucket/prefix (QA uses `qa/medusa/`); upload it
again on the destination or keep pointing at a bucket both can read.

## Check the result as the site sees it

```bash
PK=$(docker exec <project>-medusa cat /run/gosite-commerce/publishable_key)
REG=$(curl "${A[@]}" $B/admin/regions | jq -r '.regions[0].id')
curl -s -H "x-publishable-api-key: $PK" \
  "$B/store/products?handle=chaqueta-industrial&region_id=$REG&fields=%2Bvariants.inventory_quantity,*variants.calculated_price"
```

`region_id` is required whenever prices are requested
(`Missing required pricing context to calculate prices - region_id`).
A product missing here but present in the Admin is almost always one of:
not `published`, not in the `gosite` sales channel, or (for stock) no level
at the location.
