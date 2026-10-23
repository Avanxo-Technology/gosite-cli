# Local delivery by area and weight (gosite-medusa)

Checked on `gosite-medusa:0.62.1` (Medusa 2.21.2; first released there) through the Store API on
aldu-dev.

## What it is

A fulfillment provider, `local-delivery_local-delivery`, always registered
next to Medusa's manual one. It prices delivery inside one city: a base
amount for the first km, more per km past them, a surcharge by the order's
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
Every km or part of one past `included_km` adds `per_km`; the weight tier's
surcharge is added; the sum is rounded up to `round_to`. Orders whose items
add up to `free_from` or more cost 0. `round_to`, `free_from`,
`default_weight_grams` and `weight_tiers` are optional; the last tier has no
`up_to_grams`. A wrong `data` is refused when the option is created or
updated, naming the field.

Weight is the variant's `weight`, else the product's, else
`default_weight_grams`, in grams. Products have none until someone sets it.

## The site's side

- The cart's shipping address carries the city and, in `metadata.area`, the
  area as the table names it (case and accents aside). Offer the table's
  names as a list: a free-text area misses.
- `GET /store/shipping-options?cart_id=` lists the option without an amount
  (`price_type: "calculated"`). Ask for it with
  `POST /store/shipping-options/:id/calculate { cart_id }`.
- `POST /store/carts/:id/shipping-methods { option_id }` stores the price,
  and `area` and `km` in the method's `data`, which the order keeps.
- Medusa recalculates whenever the cart changes (quantities, address), so
  weight and free delivery follow the cart.
- An address outside the city or the table has no price: Medusa drops the
  method from the cart and refuses to add it (400, "Shipping options with IDs
  … do not have a price"). The site should not let it get that far.
