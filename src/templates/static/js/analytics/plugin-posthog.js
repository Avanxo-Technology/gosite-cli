/*
 * PostHog as an analytics plugin.
 *
 * Written here because there is no official one: @analytics/posthog does not
 * exist, and the third-party packages were last published in 2024 while
 * posthog-js still ships releases. See src/knowledge/analytics-providers.md.
 *
 * Kept free of conditionals on purpose - this is the only code in the scaffold
 * without automated tests, so there is as little as possible of it to be wrong.
 */
(function () {
  'use strict';

  window.analyticsPlugins = window.analyticsPlugins || {};

  window.analyticsPlugins.posthog = function (config) {
    return {
      name: 'posthog',

      initialize: function () {
        if (!config.key || !config.host) return;

        var s = document.createElement('script');
        s.async = true;
        s.src = config.host.replace(/\/$/, '') + '/static/array.js';
        s.onload = function () {
          window.posthog.init(config.key, { api_host: config.host });
        };
        document.head.appendChild(s);
      },

      page: function () {
        window.posthog.capture('$pageview');
      },

      track: function (_ref) {
        window.posthog.capture(_ref.payload.event, _ref.payload.properties);
      },

      identify: function (_ref) {
        window.posthog.identify(_ref.payload.userId, _ref.payload.traits);
      },

      /*
       * __loaded is set by posthog-js once init has finished, so this reports
       * ready only when capture calls will actually be accepted. Anything
       * earlier - the script tag existing, window.posthog being defined - would
       * let the library drain its queue into an instance that is not ready, and
       * those events would vanish with no error.
       */
      loaded: function () {
        return !!(window.posthog && window.posthog.__loaded);
      },
    };
  };
})();
