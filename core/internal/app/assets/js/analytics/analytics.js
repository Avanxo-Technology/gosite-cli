/*
 * Loads the third-party tracking the CMS configured.
 *
 * One file on purpose. It holds three things and nothing else:
 *
 *   1. a registry of official plugins - a pinned bundle URL and the global it
 *      defines. Adding a provider is a line here plus an option in the CMS
 *      select. No integration code of ours, no template change.
 *   2. two plugins we do write, PostHog and Meta Pixel, because there is no
 *      official one for either.
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
  var CUSTOM_CATEGORY = { posthog: 'analytics', 'meta-pixel': 'marketing' };

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

  /*
   * Meta Pixel: the second plugin we write, for the same reason as PostHog.
   *
   * Meta's base code is a minified snippet. Copying it would freeze one
   * release of it here, so the part the snippet exists for is written out
   * instead: a queue that makes calls before fbevents.js has run wait rather
   * than throw. fbevents.js drains that queue and then takes over with
   * callMethod.
   */
  var META_STANDARD_EVENTS = [
    'AddPaymentInfo', 'AddToCart', 'AddToWishlist', 'CompleteRegistration',
    'Contact', 'CustomizeProduct', 'Donate', 'FindLocation', 'InitiateCheckout',
    'Lead', 'Purchase', 'Schedule', 'Search', 'StartTrial', 'SubmitApplication',
    'Subscribe', 'ViewContent',
  ];

  function metaQueueStub() {
    // If something else already defined fbq, its queue is the one to use.
    if (window.fbq) return;

    var fbq = window.fbq = function () {
      if (fbq.callMethod) {
        fbq.callMethod.apply(fbq, arguments);
      } else {
        fbq.queue.push(arguments);
      }
    };

    fbq.queue = [];
    fbq.loaded = true;
    fbq.version = '2.0';
  }

  function metaPixelPlugin(config) {
    return {
      name: 'meta-pixel',

      initialize: function () {
        metaQueueStub();

        // Queued until fbevents.js runs, so init does not wait for the download.
        window.fbq('init', config.pixelId);

        var s = document.createElement('script');
        s.async = true;
        s.src = 'https://connect.facebook.net/en_US/fbevents.js';
        document.head.appendChild(s);
      },

      page: function () {
        window.fbq('track', 'PageView');
      },

      track: function (e) {
        var name = e.payload.event;
        var props = e.payload.properties || {};
        var method = META_STANDARD_EVENTS.indexOf(name) === -1 ? 'trackCustom' : 'track';

        /*
         * order_id is also sent as Meta's eventID, so an order that reaches
         * Meta twice (a retry, a reload) is counted once. The properties go
         * through unchanged.
         */
        if (props.order_id !== undefined && props.order_id !== null && props.order_id !== '') {
          window.fbq(method, name, props, { eventID: String(props.order_id) });
        } else {
          window.fbq(method, name, props);
        }
      },

      /*
       * fbevents.js sets callMethod when it has run. Until then the stub only
       * queues, so this reports ready only once Meta's script has taken over.
       */
      loaded: function () {
        return !!(window.fbq && window.fbq.callMethod);
      },
    };
  }

  var CUSTOM = { posthog: posthogPlugin, 'meta-pixel': metaPixelPlugin };

  // ---------------------------------------------------------------- bootstrap

  /*
   * A queue standing in for the real analytics object until it exists.
   *
   * Page code can call analytics.track() at any moment, including before the
   * plugin bundles have arrived. Without this those calls would throw, or
   * worse, be swallowed. What is recorded here is replayed only to providers
   * the visitor had allowed when the page loaded; see mount().
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

  /*
   * What the visitor had allowed when this page loaded.
   *
   * Page events (the data blocks read at mount, and the htmx events below)
   * describe what the page showed. A visitor who accepts on the page that
   * rendered a Purchase never agreed to what that page did, so the block is
   * not sent to a provider they only allowed afterwards. Copied now, because
   * the live state changes as soon as they answer the banner.
   */
  var grantedAtLoad = (function () {
    var g = window.consent.get().granted || {};
    return { analytics: g.analytics === true, marketing: g.marketing === true };
  })();

  /*
   * Events the server sends with an htmx response: HX-Trigger with
   * `analytics:event`. htmx fires each trigger as a DOM event whose detail is
   * the JSON value, with `elt` added. Only the event and its properties are read.
   *
   * With no provider mounted the event is dropped, not queued. A visitor who
   * has not decided is not tracked, and an answer given later does not replay it.
   */
  document.addEventListener('analytics:event', function (evt) {
    if (instances.length && evt.detail) {
      sendPageEvent(window.analytics, evt.detail);
    }
  });

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
      // Fail closed: page events go only to a batch that was entirely allowed
      // at load. A mixed batch cannot be, so it gets none.
      var atLoad = pending.every(function (item) {
        return grantedAtLoad[categoryOf(item)] === true;
      });

      whenReady(function () {
        mount(pending, atLoad);
      });
    });
  });

  var PURCHASES_KEY = 'gosite_purchases';

  /*
   * True the first time an order id is seen in this browser session.
   *
   * A reload of the confirmation page renders the same Purchase block again.
   * When storage is blocked or full the answer is "first time", so a duplicate
   * can get through; Meta's eventID then deduplicates it.
   */
  function firstPurchase(orderId) {
    try {
      var id = String(orderId);
      var seen = JSON.parse(window.sessionStorage.getItem(PURCHASES_KEY) || '[]');

      if (seen.indexOf(id) !== -1) return false;

      seen.push(id);
      window.sessionStorage.setItem(PURCHASES_KEY, JSON.stringify(seen));
      return true;
    } catch (e) {
      return true;
    }
  }

  /*
   * Sends one event the page described: { event, properties }.
   *
   * `target` is window.analytics (every mounted provider) or one instance.
   * Nothing is stored for later here: the caller decides whether there is
   * anyone to send to.
   */
  function sendPageEvent(target, data) {
    if (!data || typeof data.event !== 'string') return;

    var props = data.properties || {};
    var hasOrder = props.order_id !== undefined && props.order_id !== null;

    if (data.event === 'Purchase' && hasOrder && !firstPurchase(props.order_id)) return;

    try {
      target.track(data.event, props);
    } catch (e) {
      console.warn('[analytics] ' + data.event + ' failed', e);
    }
  }

  /*
   * The events the server rendered into the page, in document order. Read at
   * a mount that was allowed at load, and never otherwise.
   */
  function readPageEvents() {
    var blocks = document.querySelectorAll('script[type="application/json"][data-analytics-event]');
    var events = [];

    for (var i = 0; i < blocks.length; i++) {
      try {
        events.push(JSON.parse(blocks[i].textContent));
      } catch (e) {
        console.warn('[analytics] an event block is not valid JSON; skipping it', e);
      }
    }

    return events;
  }

  /*
   * Mounts one batch of providers: everything a single grant made loadable.
   *
   * A batch rather than the whole list, because a visitor can grant analytics
   * now and marketing five minutes later, and the second grant must not
   * re-mount the first grant's plugins.
   */
  function mount(batch, atLoad) {
    var plugins = [];
    var seen = {};

    batch.forEach(function (item) {
      /*
       * One plugin per provider. The analytics library refuses a second one
       * with the same name (posthogAlreadyLoaded) and then tracks nothing for
       * any provider, so a duplicate entry must not reach it. The first entry
       * wins. Cockpit sorts entries by provider only, so which of two entries
       * of the same provider comes first is not fixed: the CMS guard warns,
       * it does not choose.
       */
      if (seen[item.Provider]) {
        console.warn('[analytics] more than one "' + item.Provider + '" entry applies here; loading the first one only');
        return;
      }
      seen[item.Provider] = true;

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

    // Replay what the page recorded while the bundles were downloading, but
    // only for a load-time grant. Calls made before a later accept happened
    // without permission, the same as page events, so they are dropped. The
    // queue is emptied on the first mount either way; later batches get new
    // events only.
    if (atLoad) {
      queue.forEach(function (call) {
        window.analytics[call[0]].apply(null, call[1]);
      });
    }
    queue.length = 0;

    instance.page();

    // Page events only for a load-time grant, and only to this instance: they
    // describe the page as it rendered, not a later answer to the banner.
    if (atLoad) {
      readPageEvents().forEach(function (data) {
        sendPageEvent(instance, data);
      });
    }

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
