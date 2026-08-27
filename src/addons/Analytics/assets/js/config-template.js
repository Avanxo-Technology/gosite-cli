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

    /*
     * Diagnostics, on purpose.
     *
     * This script has already failed twice in ways that looked identical from
     * the outside - "nothing happens" - once because it was reading the event
     * payload at the wrong depth, once suspected of not being deployed at all.
     * Silence is the expensive failure mode here, so each step says whether it
     * happened.
     */
    if (!window.App || !App.on) {
        console.warn('[analytics] App event bus not available; config templates disabled');
        return;
    }

    console.debug('[analytics] config templates listening for fields-renderer-init');

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
        if (names.indexOf('provider') === -1 || names.indexOf('config') === -1) {
            console.debug('[analytics] not the analytics form; fields:', names.join(', '));
            return;
        }

        console.debug('[analytics] config templates armed on this form');

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

        /*
         * Setting the value is not enough to show it.
         *
         * Cockpit's object field only repaints from an external change when
         * `this.code.editor` exists - and it looks that element up once, in
         * mounted(), while the code editor is an ASYNC component that has not
         * rendered yet. So `this.code` is null for the life of the field and
         * the watcher can never fire. The value changes; the box does not.
         *
         * field-code deliberately publishes its editor on its own element
         * (`this.$el.editor = this.editor`), which is the handle used here to
         * do what that watcher would have done. Nothing is reached into that
         * was not offered.
         */
        function repaintConfigEditor(form, template) {

            var root = form.$el && form.$el.parentNode ? form.$el : null;
            var container = document.getElementById((form.uid || '') + '-config');
            var el = (container || document).querySelector('.field-object-code');

            if (!el || !el.editor) {
                console.debug('[analytics] no code editor to repaint; the field will show the value once it re-reads it');
                return;
            }

            if (el.editor.hasFocus()) {
                // Whoever is typing wins; the stored value is already correct.
                return;
            }

            el.editor.setValue(JSON.stringify(template, null, 2));
            console.debug('[analytics] repainted the config editor');
        }

        if (typeof form.$watch !== 'function') {
            console.warn('[analytics] the form exposes no $watch; config templates disabled', form);
            return;
        }

        var last = scalar(form.val && form.val.provider);

        form.$watch(
            function () { return scalar(form.val && form.val.provider); },
            function (provider) {

                if (provider === last) return;
                last = provider;

                var template = templates[provider];

                if (!template) {
                    console.warn('[analytics] no config template for provider "' + provider + '"');
                    return;
                }

                if (!isUntouched(form.val.config)) {
                    console.debug('[analytics] config already filled in; leaving it alone');
                    return;
                }

                // A fresh copy: sharing the object would let one entry's edits
                // leak into the template for the next.
                form.val.config = JSON.parse(JSON.stringify(template));
                console.debug('[analytics] filled config for "' + provider + '"', form.val.config);

                repaintConfigEditor(form, template);
            }
        );
    });
})();
