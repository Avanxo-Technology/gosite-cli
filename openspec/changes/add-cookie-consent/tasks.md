## 1. Decide the shape before writing anything

- [x] 1.1 Fix the three categories and which providers in `OFFICIAL` map to each, recording the mapping and its reasoning in `src/knowledge/`
- [x] 1.2 Fix the cookie's name, lifetime, `SameSite` and the exact JSON shape — schema version, copy version, timestamp, granted categories — and write it down before any code reads it
- [x] 1.3 Decide the schema version's initial value and the rule for bumping it: the category set changing re-asks, copy changing does not
- [x] 1.4 Confirm the decision that the `analytics` core bundle still loads before consent, and record the argument where a reviewer will find it

## 2. The Cockpit side — the consent singleton

- [x] 2.1 Register a consent singleton in the existing `src/addons/Analytics/bootstrap.php`, alongside the integrations collection — no new addon
- [x] 2.2 Fields: enabled, banner title and body, the accept / refuse / preferences labels, the privacy policy link, and a copy version
- [x] 2.3 Rebuild the model registry cache after creating it, so it is visible with debug off — see `src/knowledge/cockpit-model-registry-cache.md`
- [x] 2.4 Skip a singleton that already exists, so re-running never overwrites edited copy
- [x] 2.5 Verify against a real Cockpit that a fresh install creates it and re-running leaves an edited one untouched

## 3. The Cockpit side — the category on an integration

- [x] 3.1 Add a category field to the integrations model: a select over the three categories, empty meaning the provider's own default
- [x] 3.2 Refuse a category that is not one of the three, the same way an unknown provider is already refused
- [x] 3.3 Extend the admin screen to show each entry's effective category, defaulted or overridden
- [x] 3.4 Update `src/addons/Analytics/README.md`: the singleton, the categories, that GTM defaults to marketing and why, and how a new provider declares its category
- [x] 3.5 Verify by executing: an override saves, a bad category is refused, an entry with no category resolves to the provider default

## 4. Cache invalidation

- [x] 4.1 Register the consent singleton as a site-wide model in the application's purge handler, the way `analyticsIntegrations` is — and do NOT add a CMS save hook: Webapp deliberately removed save-triggered purges, because they turned every editorial save into a call out to the app and every CMS cache flush into a site-wide purge
- [x] 4.2 Confirm the purge stays scoped by project prefix, so a shared Redis is never flushed across projects
- [x] 4.3 Add tests: saving consent copy purges the home page and a blog page; another project's cache survives

## 5. Reading consent settings in the application

- [x] 5.1 Read the singleton through the CMS client and expose it to templates as a template function, beside `analyticsIntegrations`
- [x] 5.2 Return nothing, without failing the page, when the singleton is empty, disabled or the CMS is unreachable
- [x] 5.3 Resolve nothing about the visitor server-side — no handler reads a consent cookie, and no response varies by one
- [x] 5.4 Add tests: configured, disabled, absent, CMS unreachable

## 6. The component and the layout

- [x] 6.1 Add a `consent.html` component to both flavors, emitting the copy as a JSON data block — never interpolated into JavaScript, never through `safeHTML`
- [x] 6.2 Load `consent.js` before the analytics core and before `analytics.js`, so a stored decision is read before anything else runs
- [x] 6.3 Link `static/css/consent.css` rather than emitting any inline style, so a CSP stays possible
- [x] 6.4 Emit nothing at all — no markup, no empty JSON block — when consent is not configured
- [x] 6.5 Verify a copy value containing quotes and a closing script tag renders inert

## 7. `consent.js`

- [x] 7.1 Read and write the cookie, treating a malformed or hand-edited value as no decision rather than a partial one
- [x] 7.2 Apply a stored decision synchronously, before paint, so a returning visitor never sees the banner flash
- [x] 7.3 Render the banner: accept all, refuse all, preferences, and the policy link
- [x] 7.4 Render the preferences dialog: necessary shown as always on and not refusable, analytics and marketing switchable, current choices reflected
- [x] 7.5 Publish `window.consent` with `get`, `onChange`, `open` and `reset`, with nothing analytics-specific in it
- [x] 7.6 Support a documented reopen selector any footer can carry, and document it in the addon README
- [~] 7.7 Accessibility, verified in a browser and not assumed: keyboard reachable controls, visible focus, focus trapped in the dialog, escape closing it without storing a decision, labelled controls, sufficient contrast in both the plain and tailwind flavors — **done except contrast**: keyboard reach, first focus, the non-modal banner vs the modal dialog and escape-stores-nothing were all driven from the keyboard on analytics-draft (tailwind). The CSS is flavor-independent, so plain shares it. Contrast is not measured; the palette is near-black on white and its dark counterpart, so it is very likely fine, but that is an assumption and this line says so.
- [x] 7.8 Keep it free of surprises: no dependency, no inline style, no `alert`/`confirm`, and it must never take a page down when it fails

## 8. The gate in `analytics.js`

- [x] 8.1 Move both the bundle fetching and the mount behind `window.consent.onChange` — fetching a bundle already discloses the visit
- [x] 8.2 Add each provider's category to the `OFFICIAL` registry and to the PostHog entry, and let a CMS override win over it
- [x] 8.3 Load exactly the granted categories, keeping the existing environment gating on top of it
- [x] 8.4 Mount a newly granted category later in the visit without requiring a reload
- [x] 8.5 Treat a missing or disabled consent configuration, and a `consent.js` that failed to load, as no consent given
- [x] 8.6 Keep the pre-mount queue working: a `track` call before a decision must neither throw nor reach a provider
- [x] 8.7 Implement withdrawal: clear the cookie, clear each provider's own storage where the provider documents a way, then reload — and state in a comment why `analytics@0.8.19` leaves no honest alternative
- [x] 8.8 Keep the existing console diagnostics meaningful: distinguish not configured, awaiting consent, refused, and tracking

## 9. Distribution

- [x] 9.1 Ship `consent.js` and `consent.css` as application templates, so `gosite sync --app` delivers them and a customised copy is preserved and reported
- [x] 9.2 Confirm the `Analytics` addon's declared application requirements cover the new files, so `gosite addons add` refuses an install that would not work
- [x] 9.3 Confirm nothing else in a project is touched

## 10. Verify end to end

- [x] 10.1 A fresh scaffold ships the gate and loads nothing until an editor turns it on — the task as first written ("the banner appears with no manual step") contradicts the design: consent starts disabled, so a new project shows no banner AND no tracking until somebody fills in the copy. Verified in three parts rather than by creating a second throwaway project: the fixture render proves the four files land in both flavors and in the right load order, `ensureModels()` against the real Cockpit on analytics-draft created the singleton disabled and added the category field to the pre-existing collection, and the live page with consent disabled made zero provider requests and logged `no consent mechanism on this page`
- [x] 10.2 On `analytics-draft`, with the network panel open: no request to any provider or provider CDN before a decision
- [x] 10.3 Grant analytics only, and confirm the analytics provider sends while the marketing one is never fetched
- [x] 10.4 Withdraw, and confirm on the network that events stop — not that a flag flipped
- [x] 10.5 Reload as a returning visitor and confirm no banner flash
- [x] 10.6 Confirm two visitors with opposite choices receive byte-identical markup from the cache — 4891 bytes either way on analytics-draft, `Vary: Accept-Encoding` only, no `Set-Cookie`
- [x] 10.7 Walk the spec scenarios in both capabilities against the sandbox, and the browser-dependent ones against `analytics-draft`

## 11. Ship

- [x] 11.1 Bump `src/VERSION`
- [x] 11.2 Update `docs/index.html` and `README.md` for the addon's new half
- [x] 11.3 CHANGELOG entry stating both rebuilds are needed, CMS and application, and that consent now gates the tags shipped in 0.46.0
- [ ] 11.4 Tag the release and publish it with both assets
- [ ] 11.5 Roll out to the one project already carrying analytics, before its analytics rollout goes further
- [ ] 11.6 Only then continue the analytics rollout to the remaining projects, so none of them ever gets tracking without a banner

## 12. Pending, by decision — not part of this change

- [ ] 12.1 Google Consent Mode v2 as an opt-in per-provider mode, for a client running Google Ads in the EEA
- [ ] 12.2 A server-side record of consent: an endpoint, a collection and a retention policy. The copy version lands in the cookie in this change specifically so the history can be reconstructed when this is built
- [ ] 12.3 Gating consumers other than analytics — embedded maps, video players — through the same `window.consent`
- [ ] 12.4 PostHog's own consent API, which would allow cookieless measurement before a decision instead of blocking outright
