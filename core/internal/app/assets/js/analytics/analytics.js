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
 * This is also the single mount point, and consent hooks here: nothing below
 * downloads or mounts anything until window.consent (consent.js) reports a
 * category granted. If that object is missing, nothing loads at all - an
 * absent gate has to mean "no permission", never "no gate needed".
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
    gtm: { path: 'google-tag-manager@0.6.0/dist/@analytics/google-tag-manager.min.js', global: 'analyticsGtagManager', category: 'marketing' },
    'google-analytics': { path: 'google-analytics@1.1.0/dist/@analytics/google-analytics.min.js', global: 'analyticsGa', category: 'analytics' },
    'google-analytics-v3': { path: 'google-analytics-v3@0.7.0/dist/@analytics/google-analytics-v3.min.js', global: 'analyticsGa3', category: 'analytics' },
    mixpanel: { path: 'mixpanel@0.4.0/dist/@analytics/mixpanel.min.js', global: 'analyticsMixpanel', category: 'analytics' },
    segment: { path: 'segment@2.1.0/dist/@analytics/segment.min.js', global: 'analyticsSegment', category: 'analytics' },
    amplitude: { path: 'amplitude@0.1.3/dist/@analytics/amplitude.min.js', global: 'analyticsAmplitude', category: 'analytics' },
    hubspot: { path: 'hubspot@0.5.1/dist/@analytics/hubspot.min.js', global: 'analyticsHubspot', category: 'marketing' },
    fullstory: { path: 'fullstory@0.2.7/dist/@analytics/fullstory.min.js', global: 'analyticsFullStory', category: 'analytics' },
    customerio: { path: 'customerio@0.2.2/dist/@analytics/customerio.min.js', global: 'analyticsCustomerio', category: 'marketing' },
  };

  /*
   * Which consent category each provider needs, for the ones without an
   * OFFICIAL entry.
   *
   * GTM is marketing, and that is a judgement: a container can hold nothing but
   * a GA4 tag, or it can hold an advertising pixel, and only whoever built it
   * knows which. Marketing is the safer reading and the CMS can lower it per
   * entry. The addon's PROVIDER_CATEGORY holds the same mapping for the admin
   * screen; this copy is the one that gates.
   */
  var CUSTOM_CATEGORY = { posthog: 'analytics' };

  /*
   * The category an entry actually needs.
   *
   * An unrecognised value falls through to marketing, not to "allowed". Every
   * unknown here has to resolve to the category hardest to obtain, or a typo
   * in the CMS becomes a way to load a tracker without consent.
   */
  function categoryOf(item) {
    var override = typeof item.Category === 'string' ? item.Category.trim() : '';

    if (override === 'analytics' || override === 'marketing') {
      return override;
    }

    var official = OFFICIAL[item.Provider];

    return (official && official.category) || CUSTOM_CATEGORY[item.Provider] || 'marketing';
  }

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
          /*
           * Session recording, surveys and web experiments each pull their own
           * chunk of posthog-js on top of the core bundle - together about
           * 120KiB a visitor downloads whether or not the product uses them.
           * They are off unless the CMS turns one on explicitly, and
           * autocapture stays on because pageview and click data is what most
           * sites configure PostHog for in the first place.
           */
          window.posthog.init(config.key, {
            api_host: config.host,
            autocapture: config.autocapture !== false,
            disable_session_recording: config.session_recording !== true,
            disable_surveys: config.surveys !== true,
            disable_web_experiments: config.web_experiments !== true,
          });
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

  /*
   * Run once the document has a body.
   *
   * This script sits in <head> so the bundles start downloading as early as
   * possible - but at that moment `document.body` is still null, and at least
   * one official plugin (google-analytics) appends its tag straight to
   * document.body. Mounting there threw before anything was ever sent.
   *
   * Only the mount waits. The downloads still start immediately, and the queue
   * above holds any event the page raises meanwhile.
   */
  function whenReady(fn) {
    if (document.body) {
      fn();
      return;
    }
    document.addEventListener('DOMContentLoaded', fn, { once: true });
  }

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

  if (!integrations.length) {
    // Nothing configured for this environment. Nothing to say either.
    return;
  }

  /*
   * The core bundle publishes `_analytics`, an object holding the factory -
   * not a bare `Analytics` function. Assuming the latter meant the library was
   * reported as "did not load" while sitting right there, fully loaded.
   *
   * Both shapes are accepted so a future bundle changing its mind does not
   * break this again.
   */
  var core = window._analytics || window.Analytics;
  var createAnalytics = typeof core === 'function'
    ? core
    : (core && (core.init || core.Analytics || core.default));

  if (typeof createAnalytics !== 'function') {
    // Genuinely absent: offline, an ad blocker, a CDN outage. Worth saying,
    // because from a browser console that is indistinguishable from analytics
    // simply being misconfigured.
    console.warn('[analytics] the analytics library did not load; nothing will be tracked');
    return;
  }

  /*
   * Nothing happens until consent says so.
   *
   * The gate covers the DOWNLOADS as well as the mount, which is the part that
   * is easy to get wrong. Fetching a bundle from unpkg is already a request to
   * a third party carrying this site's referrer, and PostHog's plugin fetches
   * from the client's own PostHog host - so deferring only the mount would
   * disclose the visit before anybody agreed to anything.
   *
   * The `analytics` core in the layout is the one exception, and a deliberate
   * one: it is a CDN request that sets nothing and identifies nobody, and
   * having it already parsed keeps the gap between accepting and tracking
   * short. That line is argued in the change's design, so it can be revisited
   * as one decision rather than drifting.
   */
  if (!window.consent || typeof window.consent.onChange !== 'function') {
    /*
     * consent.js is missing or failed to load.
     *
     * Fail closed, always. This is the branch where a mistake is expensive:
     * treating an absent gate as "no gate needed" would load every tracker on
     * a site whose banner simply 404ed, which is the exact outcome this whole
     * change exists to prevent.
     */
    console.warn('[analytics] no consent mechanism on this page; nothing will be tracked');
    return;
  }

  // Providers already loaded, so a later grant adds the new ones instead of
  // mounting the same plugin twice.
  var mounted = {};

  // Every instance we have mounted. There is one per grant, because
  // analytics@0.8.19 fixes its plugin list at construction and offers no way
  // to add a plugin to a live instance.
  var instances = [];

  window.consent.onChange(function (state) {
    var pending = integrations.filter(function (item) {
      return !mounted[item.Provider] && state.granted[categoryOf(item)] === true;
    });

    if (!pending.length) {
      return;
    }

    pending.forEach(function (item) { mounted[item.Provider] = true; });

    var needed = [];

    pending.forEach(function (item) {
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
      whenReady(function () {
        mount(pending);
      });
    });
  });

  /*
   * Mounts one batch of providers: everything a single grant made loadable.
   *
   * A batch rather than the whole list, because a visitor can grant analytics
   * now and marketing five minutes later, and the second grant must not
   * re-mount the first grant's plugins.
   */
  function mount(batch) {
    var plugins = [];

    batch.forEach(function (item) {
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

    if (!plugins.length) {
      console.warn('[analytics] no plugin could be built; nothing will be tracked');
      return;
    }

    var instance = createAnalytics({ app: 'site', plugins: plugins });

    instances.push(instance);

    /*
     * Fan out to every mounted instance.
     *
     * With one grant there is one instance and this is just a wrapper. With a
     * second grant there are two, and a single `analytics.track()` from page
     * code has to reach both - so the page keeps one object and never has to
     * know how many times consent was given.
     */
    window.analytics = {
      track: fanOut('track'),
      page: fanOut('page'),
      identify: fanOut('identify'),
    };

    // Replay whatever the page recorded while it was waiting. The queue is
    // drained on the first mount only; later batches get new events, not the
    // history of a page they had no permission to see.
    queue.forEach(function (call) {
      window.analytics[call[0]].apply(null, call[1]);
    });
    queue.length = 0;

    instance.page();

    /*
     * Say so on the way out.
     *
     * Silence used to mean any of: not configured, script missing, plugin not
     * built, or working perfectly - four very different situations that looked
     * identical in a browser console. One line removes the ambiguity, and the
     * cost is one console.debug on pages that actually have analytics.
     */
    console.debug('[analytics] tracking with: ' + plugins.map(function (p) {
      return p.name;
    }).join(', '));
  }

  function fanOut(method) {
    return function () {
      var args = arguments;

      instances.forEach(function (instance) {
        try {
          instance[method].apply(instance, args);
        } catch (e) {
          // One provider throwing must not stop the others from recording the
          // same event.
          console.warn('[analytics] ' + method + ' failed on one provider', e);
        }
      });
    };
  }
})();
