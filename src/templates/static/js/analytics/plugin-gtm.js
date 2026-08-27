/*
 * Google Tag Manager as an analytics plugin.
 *
 * GTM is itself a tag manager, so this plugin is deliberately thin: it loads
 * the container and pushes events onto the dataLayer. What happens to them
 * afterwards is configured in GTM's own interface, which is the point of it.
 *
 * Kept free of conditionals on purpose - this is the only code in the scaffold
 * without automated tests, so there is as little as possible of it to be wrong.
 */
(function () {
  'use strict';

  window.analyticsPlugins = window.analyticsPlugins || {};

  window.analyticsPlugins.gtm = function (config) {
    return {
      name: 'google-tag-manager',

      initialize: function () {
        if (!config.id) return;

        window.dataLayer = window.dataLayer || [];
        window.dataLayer.push({ 'gtm.start': new Date().getTime(), event: 'gtm.js' });

        var s = document.createElement('script');
        s.async = true;
        s.src = 'https://www.googletagmanager.com/gtm.js?id=' + encodeURIComponent(config.id);
        document.head.appendChild(s);
      },

      page: function (_ref) {
        window.dataLayer.push({ event: 'pageview', page: _ref.payload.properties });
      },

      track: function (_ref) {
        window.dataLayer.push({ event: _ref.payload.event, properties: _ref.payload.properties });
      },

      identify: function (_ref) {
        window.dataLayer.push({ event: 'identify', userId: _ref.payload.userId, traits: _ref.payload.traits });
      },

      /*
       * Ready as soon as the dataLayer array exists, which initialize creates
       * synchronously. That is correct rather than optimistic: GTM's container
       * drains whatever is already in the array when it loads, so a push made
       * before the script arrives is queued by GTM itself, not lost.
       */
      loaded: function () {
        return Array.isArray(window.dataLayer);
      },
    };
  };
})();
