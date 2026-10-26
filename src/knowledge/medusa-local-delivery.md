# Local delivery by distance and weight (gosite-medusa)

Checked on `gosite-medusa:0.62.1` (Medusa 2.21.2; first released there) through the Store API on
aldu-dev. Pricing by a point on the map (`origin`, `zones`, `max_km`) and
`bulk_units` since 0.63.0.

## What it is

A fulfillment provider, `local-delivery_local-delivery`, always registered
next to Medusa's manual one. It prices delivery inside one city by how far
the buyer is from the store, measured one of two ways: a table of km per area
(neighbourhood) the buyer picks, or the straight line from the store to a
point the buyer marks on a map. Then: a base amount for the first km, more
per km past them, a surcharge by the order's
weight, free from an order total. Fulfilling stays manual.

The rates are the shipping option's `data`, so they live in the store's
database and come from wherever the store sets them up (Admin API), the same
on local, QA and production. No env var or file.

## Setting it up (Admin API)

1. Enable the provider on the stock location:
   `POST /admin/stock-locations/:id/fulfillment-providers { add: ["local-delivery_local-delivery"] }`.
2. Create the option in the location's shipping service zone:
   `POST /admin/shipping-options` with `provider_id:
   "local-delivery_local-delivery"`, `price_type: "calculated"`, `prices: []`
   (required even when calculated) and `data`:

```json
{
  "city": "Barranquilla",
  "areas": { "Centro": 0, "El Prado": 4.0, "Riomar": 8.1 },
  "base_amount": 10000,
  "included_km": 3,
  "per_km": 1000,
  "round_to": 1000,
  "free_from": 300000,
  "default_weight_grams": 500,
  "weight_tiers": [
    { "up_to_grams": 5000, "surcharge": 0 },
    { "up_to_grams": 10000, "surcharge": 3000 },
    { "surcharge": 15000 }
  ]
}
```

`areas` maps each area (neighbourhood) to its km by road from the store.

To price by a point on the map instead, replace `areas` with `origin` (the
store's point) and optionally `zones` and `max_km`:

```json
{
  "city": "Barranquilla",
  "origin": { "lat": 10.97964, "lng": -74.77872 },
  "zones": [
    { "name": "Riomar", "rings": [[[-74.83, 11.0], [-74.80, 11.0], [-74.80, 11.03], [-74.83, 11.0]]] }
  ],
  "max_km": 15,
  "bulk_units": 6,
  "base_amount": 10000,
  "included_km": 3,
  "per_km": 1000
}
```

The km are the straight line (haversine) from `origin` to the point, to a
tenth of a km: shorter than by road, so set `per_km` and `included_km` with
that in mind. `zones` are the parts of the city delivered to, each one or more
rings of `[lng, lat]` corners as in GeoJSON (holes are not read); a point
outside every zone is not delivered to, and the zone's name is the one kept
on the method. A zone may name its own `city` (a neighbouring
municipality): a point there wants the address's city to be the zone's, and
a point in a zone without one wants `city`. Without `zones`, any point within
`max_km` is. `areas` and
`origin` are exclusive.

`bulk_units` (either way, optional): an order with that many units of one
product (its variants added up) gets no price at this rate, for the store to
arrange with the buyer.

Every km or part of one past `included_km` adds `per_km`; the weight tier's
surcharge is added; the sum is rounded up to `round_to`. Orders whose items
add up to `free_from` or more cost 0. `round_to`, `free_from`,
`default_weight_grams` and `weight_tiers` are optional; the last tier has no
`up_to_grams`. A wrong `data` is refused when the option is created or
updated, naming the field. Medusa merges `data` on update instead of
replacing it: to drop a field (the `areas` table when moving to `origin`),
send it as `null`, which the provider reads as unset.

Weight is the variant's `weight`, else the product's, else
`default_weight_grams`, in grams. Products have none until someone sets it.

## The site's side

- The cart's shipping address carries the city and, in `metadata.area`, the
  area as the table names it (case and accents aside). Offer the table's
  names as a list: a free-text area misses. With `origin`, it carries the
  point instead, as numbers in `metadata.lat` and `metadata.lng`; the site
  gets it from the buyer (a map pin) and can read `origin`, `zones` and the
  rates from the option's `data` in the Store API to show the zone and price
  before the buyer goes on. A point is the buyer's word: show it to whoever
  delivers next to the address.
- `GET /store/shipping-options?cart_id=` lists the option without an amount
  (`price_type: "calculated"`). Ask for it with
  `POST /store/shipping-options/:id/calculate { cart_id }`.
- `POST /store/carts/:id/shipping-methods { option_id }` stores the price,
  and `area` and `km` in the method's `data`, which the order keeps.
- Medusa recalculates whenever the cart changes (quantities, address), so
  weight and free delivery follow the cart.
- An address outside the city, the table or the zones, past `max_km`, without
  a point, or a bulk order has no price: Medusa drops the
  method from the cart and refuses to add it (400, "Shipping options with IDs
  … do not have a price"). The site should not let it get that far.
