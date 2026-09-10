## ADDED Requirements

### Requirement: Nothing a provider needs is fetched before a decision exists

Before a visitor has decided, the loader SHALL NOT fetch any provider bundle,
mount any plugin, or send any event. Fetching a bundle discloses the visit, so
deferring only the mount SHALL NOT be considered sufficient.

#### Scenario: A first visit, observed on the network

- **WHEN** a visitor with no stored decision loads a page carrying configured
  integrations
- **THEN** no request to any provider or provider CDN is made

#### Scenario: A first visit, observed in storage

- **WHEN** the same visitor loads the page and does not interact
- **THEN** no provider has written a cookie or any other storage

#### Scenario: Events raised before a decision

- **WHEN** page code calls the tracking API before the visitor decides
- **THEN** the call neither throws nor reaches a provider

### Requirement: Only the granted categories load

On a decision, the loader SHALL load exactly the providers whose category was
granted, and SHALL leave the rest untouched for the remainder of the visit.

#### Scenario: Analytics granted, marketing refused

- **WHEN** a site has one analytics provider and one marketing provider, and
  the visitor grants analytics only
- **THEN** the analytics provider loads and sends, and the marketing provider
  is never fetched

#### Scenario: Granting a second category later

- **WHEN** a visitor who granted analytics later also grants marketing
- **THEN** the marketing provider begins loading without a page reload

#### Scenario: Environment gating still applies

- **WHEN** a granted category contains a provider scoped to another environment
- **THEN** that provider still does not load

### Requirement: Withdrawal actually stops the tracking

Withdrawing a category SHALL stop the providers in it from sending anything
further, and SHALL clear what those providers stored where the provider
documents a way to do so. A withdrawal SHALL NOT be reported as effective while
a mounted provider is still able to send.

#### Scenario: Withdrawing analytics

- **WHEN** a visitor withdraws analytics on a page where it is already mounted
- **THEN** no further event is sent by it, verified on the network rather than
  by inspecting a flag

#### Scenario: After the withdrawal

- **WHEN** the visitor continues browsing
- **THEN** subsequent pages behave as though the provider had never been
  configured for them

### Requirement: Consent never reaches the server, and never varies a cached page

The application SHALL NOT read the consent decision when rendering. The
integration configuration a page emits SHALL be identical for every visitor of
that page.

#### Scenario: Two visitors, one cache entry

- **WHEN** a visitor who accepted and a visitor who refused load the same
  cached page
- **THEN** both receive byte-identical markup, and the difference is entirely
  in the browser

#### Scenario: A purge

- **WHEN** the project's cache is purged and the page is rendered afresh
- **THEN** the rendered configuration is unchanged by any visitor's decision

### Requirement: Analytics without consent configured does not load

The loader SHALL treat unconfigured consent as no consent given, so a site
that stores integrations without a banner loads none of them.

#### Scenario: The addon installed, consent left empty

- **WHEN** integrations are enabled and the consent singleton is disabled or
  absent
- **THEN** no provider loads, and the reason is stated once in the console

#### Scenario: The consent script missing

- **WHEN** the consent script fails to load but the analytics loader does not
- **THEN** nothing is tracked, and the page renders normally
