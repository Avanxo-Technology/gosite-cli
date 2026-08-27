/*
 * Fills the `config` field with the right keys when a provider is picked.
 *
 * The system already knows what each provider expects - the screen validates
 * against it and the README lists it. Making an editor retype those key names
 * from memory is how a GTM container id ends up under Google Analytics, which
 * is exactly the mistake this removes.
 *
 * Hooks `fields-renderer-init`, the event Cockpit's field renderer fires with
 * itself on mount. That gives access to the item's values, whose deep watcher
 * propagates any change - so this is an extension point rather than DOM
 * poking.
 *
 * Deliberately conservative: it only writes into `config` when doing so cannot
 * destroy anything the editor typed.
 */
(function () {
    'use strict';

    if (!window.App || !App.on) return;

    App.on('fields-renderer-init', function (event) {

        /*
         * App.trigger(name, params) hands handlers {name, params} - the
         * payload is one level down. Reading event.form instead of
         * event.params.form was a silent no-op: undefined, an early return,
         * and a feature that looked deployed and did nothing.
         */
        var form = event && event.params && event.params.form;

        // Say so rather than returning quietly. The first version of this file
        // read the payload one level too high and did nothing at all, which
        // looked exactly like a deployment problem for as long as it stayed
        // silent.
        if (!form || !Array.isArray(form.fields)) {
            console.warn('[analytics] unexpected fields-renderer-init payload; config templates disabled', event);
            return;
        }

        var names = form.fields.map(function (f) { return f.name; });

        // Only the Analytics item form: any other model is none of our business.
        if (names.indexOf('provider') === -1 || names.indexOf('config') === -1) return;

        var templates = window.ANALYTICS_CONFIG_TEMPLATES || {};

        function scalar(value) {
            return Array.isArray(value) ? (value[0] || '') : (value || '');
        }

        /*
         * Safe to overwrite when the config is empty, or when it still looks
         * like a template nobody has filled in - every value blank or equal to
         * the hint we put there. Anything else is the editor's work and is left
         * alone; the screen will report it if it does not match.
         */
        function isUntouched(config) {

            if (!config || typeof config !== 'object') return true;

            var keys = Object.keys(config);

            if (!keys.length) return true;

            return keys.every(function (k) {
                var v = config[k];
                if (v === '' || v === null) return true;
                // A hint we wrote ourselves, still unedited.
                return Object.keys(templates).some(function (p) {
                    return templates[p] && templates[p][k] === v;
                });
            });
        }

        var last = scalar(form.val && form.val.provider);

        form.$watch(
            function () { return scalar(form.val && form.val.provider); },
            function (provider) {

                if (provider === last) return;
                last = provider;

                var template = templates[provider];

                if (!template) return;
                if (!isUntouched(form.val.config)) return;

                // A fresh copy: sharing the object would let one entry's edits
                // leak into the template for the next.
                form.val.config = JSON.parse(JSON.stringify(template));
            }
        );
    });
})();
