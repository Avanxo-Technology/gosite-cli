/*
 * Loads the third-party tracking the CMS configured.
 *
 * One file on purpose. It holds three things and nothing else:
 *
 *   1. a registry of official plugins - a pinned bundle URL and the global it
 *      defines. Adding a provider is a line here plus an option in the CMS
 *      select. No integration code of ours, no template change.
 *   2. one plugin we do write, for PostHog, because there is no official one.
 *   3. the bootstrap that reads the page's configuration and mounts them.
 *
 * The configuration arrives as JSON in the page, never as generated
 * JavaScript, so nothing an editor typed is executed. A malformed value fails
 * the parse below and analytics simply does not load - which is correct:
 * analytics failing must never take a page down with it.
 *
 * This is also the single mount point. When consent management arrives, this
 * is where it hooks.
 */
(function () {
  'use strict';

  var CDN = 'https://unpkg.com/@analytics/';

  /*
   * Official plugins, pinned.
   *
   * Every entry here was verified to load standalone and expose its global.
   * Four published plugins do NOT and are deliberately absent - their bundles
   * reference things they do not ship (aws-pinpoint, intercom, snowplow) or
   * publish no browser build at all (simple-analytics). See
   * src/knowledge/analytics-providers.md before adding one back.
   *
   * The stored configuration is handed to the plugin untouched, so what an
   * editor types is what the plugin documents. No translation layer to drift.
   */
  var OFFICIAL = {
    gtm: { path: 'google-tag-manager@0.6.0/dist/@analytics/google-tag-manager.min.js', global: 'analyticsGtagManager' },
    'google-analytics': { path: 'google-analytics@1.1.0/dist/@analytics/google-analytics.min.js', global: 'analyticsGa' },
    'google-analytics-v3': { path: 'google-analytics-v3@0.7.0/dist/@analytics/google-analytics-v3.min.js', global: 'analyticsGa3' },
    mixpanel: { path: 'mixpanel@0.4.0/dist/@analytics/mixpanel.min.js', global: 'analyticsMixpanel' },
    segment: { path: 'segment@2.1.0/dist/@analytics/segment.min.js', global: 'analyticsSegment' },
    amplitude: { path: 'amplitude@0.1.3/dist/@analytics/amplitude.min.js', global: 'analyticsAmplitude' },
    hubspot: { path: 'hubspot@0.5.1/dist/@analytics/hubspot.min.js', global: 'analyticsHubspot' },
    fullstory: { path: 'fullstory@0.2.7/dist/@analytics/fullstory.min.js', global: 'analyticsFullStory' },
    customerio: { path: 'customerio@0.2.2/dist/@analytics/customerio.min.js', global: 'analyticsCustomerio' },
  };

  /*
   * PostHog: the only plugin we write.
   *
   * @analytics/posthog does not exist, and the third-party ones were last
   * published in 2024 while posthog-js still ships releases.
   *
   * Deliberately free of conditionals: this is the only analytics code in the
   * scaffold without automated tests, so there is as little of it as possible
   * to be wrong.
   */
  function posthogPlugin(config) {
    return {
      name: 'posthog',

      initialize: function () {
        var s = document.createElement('script');
        s.async = true;
        s.src = String(config.host).replace(/\/$/, '') + '/static/array.js';
        s.onload = function () {
          window.posthog.init(config.key, { api_host: config.host });
        };
        document.head.appendChild(s);
      },

      page: function () {
        window.posthog.capture('$pageview');
      },

      track: function (e) {
        window.posthog.capture(e.payload.event, e.payload.properties);
      },

      identify: function (e) {
        window.posthog.identify(e.payload.userId, e.payload.traits);
      },

      /*
       * __loaded is set by posthog-js once init has finished, so this reports
       * ready only when capture calls are actually accepted. Anything earlier
       * - the script tag existing, window.posthog being defined - would let
       * the library drain its queue into an instance that is not ready, and
       * those events would vanish with no error.
       */
      loaded: function () {
        return !!(window.posthog && window.posthog.__loaded);
      },
    };
  }

  var CUSTOM = { posthog: posthogPlugin };

  // ---------------------------------------------------------------- bootstrap

  /*
   * A queue standing in for the real analytics object until it exists.
   *
   * Page code can call analytics.track() at any moment, including before the
   * plugin bundles have arrived. Without this those calls would throw, or
   * worse, be swallowed. Everything recorded here is replayed once the real
   * object is mounted.
   */
  var queue = [];

  function enqueue(method) {
    return function () {
      queue.push([method, Array.prototype.slice.call(arguments)]);
    };
  }

  window.analytics = window.analytics || {
    track: enqueue('track'),
    page: enqueue('page'),
    identify: enqueue('identify'),
  };

  function loadScript(src) {
    return new Promise(function (resolve) {
      var s = document.createElement('script');
      s.src = src;
      // Resolve on failure too: one blocked bundle must not stop the others.
      s.onload = resolve;
      s.onerror = function () {
        console.warn('[analytics] could not load ' + src);
        resolve();
      };
      document.head.appendChild(s);
    });
  }

  function readConfig() {
    var el = document.getElementById('analytics-config');

    if (!el) return [];

    try {
      var parsed = JSON.parse(el.textContent);
      return Array.isArray(parsed) ? parsed : [];
    } catch (e) {
      console.warn('[analytics] configuration is not valid JSON; loading nothing', e);
      return [];
    }
  }

  var integrations = readConfig();

  if (!integrations.length || !window.Analytics) {
    // Nothing configured, or the library itself did not load (offline, an ad
    // blocker, a CDN outage). Either way there is nothing to do.
    return;
  }

  // Fetch every official bundle a configured provider needs, in parallel.
  var needed = [];

  integrations.forEach(function (item) {
    var official = OFFICIAL[item.Provider];
    if (official && needed.indexOf(official) === -1) {
      needed.push(official);
    }
  });

  Promise.all(
    needed.map(function (o) {
      return loadScript(CDN + o.path);
    })
  ).then(function () {
    var plugins = [];

    integrations.forEach(function (item) {
      var config = item.Config || {};
      var factory;

      if (CUSTOM[item.Provider]) {
        factory = CUSTOM[item.Provider];
      } else if (OFFICIAL[item.Provider]) {
        factory = window[OFFICIAL[item.Provider].global];

        /*
         * Two of the official bundles - google-analytics and its v3 - expose
         * an ESM interop object rather than the factory itself, so the global
         * is {default: fn, ...} instead of fn. Unwrapping it here beats
         * recording which ones do that, since the list would go stale.
         */
        if (typeof factory !== 'function' && factory && typeof factory.default === 'function') {
          factory = factory.default;
        }
      }

      if (typeof factory !== 'function') {
        console.warn('[analytics] no usable plugin for "' + item.Provider + '"');
        return;
      }

      try {
        plugins.push(factory(config));
      } catch (e) {
        console.warn('[analytics] plugin "' + item.Provider + '" failed to build', e);
      }
    });

    if (!plugins.length) return;

    var instance = window.Analytics({ app: 'site', plugins: plugins });

    // Replace the queue and replay whatever the page recorded meanwhile.
    window.analytics = instance;
    queue.forEach(function (call) {
      instance[call[0]].apply(instance, call[1]);
    });
    queue.length = 0;

    instance.page();
  });
})();
