/*
 * Mounts the analytics library from the integrations the CMS configured.
 *
 * The configuration arrives as JSON in the page, not as generated JavaScript,
 * so nothing an editor typed is ever executed. A malformed value fails the
 * parse below and analytics simply does not load - which is the correct
 * outcome, because analytics failing must never take a page down with it.
 *
 * This file is also the single mount point. When consent management arrives,
 * this is where it hooks: everything below happens once, in one place.
 */
(function () {
  'use strict';

  var el = document.getElementById('analytics-config');

  if (!el || !window.Analytics) {
    // No integrations configured, or the library did not load (offline, an ad
    // blocker, a CDN outage). Either way there is nothing to do and nothing to
    // report to a visitor.
    return;
  }

  var integrations;

  try {
    integrations = JSON.parse(el.textContent);
  } catch (e) {
    console.warn('[analytics] configuration is not valid JSON; loading nothing', e);
    return;
  }

  if (!Array.isArray(integrations) || !integrations.length) {
    return;
  }

  // Each plugin registers itself here as window.analyticsPlugins[<provider>].
  // A provider whose script did not load is skipped rather than throwing,
  // so one broken plugin cannot take the others down with it.
  var registry = window.analyticsPlugins || {};
  var plugins = [];

  integrations.forEach(function (item) {
    var factory = registry[item.Provider];

    if (typeof factory !== 'function') {
      console.warn('[analytics] no plugin for provider "' + item.Provider + '"');
      return;
    }

    try {
      plugins.push(factory(item.Config || {}));
    } catch (e) {
      console.warn('[analytics] plugin "' + item.Provider + '" failed to build', e);
    }
  });

  if (!plugins.length) {
    return;
  }

  // Exposed so page code can call analytics.track(...) without knowing which
  // providers are configured - which is the whole reason for the library.
  window.analytics = window.Analytics({ app: 'site', plugins: plugins });

  window.analytics.page();
})();
