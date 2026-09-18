# Commerce

The Cockpit half of the gosite commerce addon.

Enabling `Commerce` in `gosite.yml` gives the site its own Medusa v2 store
(catalog, cart, checkout). The commerce engine and its database run as the
site's own services; this Cockpit addon is the back-office bridge that lands
in the payments change (products page, `commerceproduct` field type, menu link
to the Medusa Admin).

Until then this directory only marks `Commerce` as part of gosite's addon
library, so `gosite addons list` shows it and `gosite.yml` may declare it.
