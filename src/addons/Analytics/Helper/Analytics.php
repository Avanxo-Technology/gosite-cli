<?php

namespace Analytics\Helper;

/**
 * All Analytics business logic.
 *
 * One collection holds one entry per third-party integration: which provider,
 * that provider's configuration, whether it is on, and where it applies. The
 * application reads it through the core REST API and renders the matching
 * plugin.
 *
 * Adding a KEY is data - an entry, no release. Adding a KIND of tool is not,
 * because something has to know how to render it: a plugin in the application
 * and an option in the select below. The two are meant to move together, which
 * is why the select is closed rather than free text.
 *
 * Nothing here is a secret. A GTM container id and a PostHog project key are
 * served in the HTML to every visitor; that is what makes it safe for a client
 * to edit them. See src/knowledge/analytics-providers.md.
 */
class Analytics extends \Lime\Helper {

    const MODEL = 'analyticsIntegrations';

    /**
     * The consent singleton.
     *
     * It lives in this addon rather than one of its own because the thing being
     * gated is exactly what this addon stores. A separate addon would let a
     * project install tracking with no way to ask permission for it, which is
     * the state this whole model exists to end.
     */
    const CONSENT_MODEL = 'analyticsConsent';

    /**
     * The consent categories, and there are only three.
     *
     * More categories look more precise and are worse: every extra switch is
     * another thing a visitor has to understand before they can leave the
     * banner, and none of the providers here need a finer split.
     *
     * `necessary` is listed for completeness. It is never refusable and no
     * provider in this addon belongs to it - a tracking tool is by definition
     * not necessary for a page to work.
     */
    const CATEGORIES = ['necessary', 'analytics', 'marketing'];

    /**
     * Which category each provider needs consent for.
     *
     * The browser registry in static/js/analytics/analytics.js holds the same
     * mapping, and that copy is the one that gates. This one exists so the
     * admin screen can show an editor what an entry will actually require, and
     * so the select can be pre-filled. The two are the same fact in two places
     * for the same reason PROVIDERS already is.
     *
     * GTM defaults to marketing, and that is a judgement rather than a fact: a
     * container can hold nothing but a GA4 tag, or it can hold an advertising
     * pixel, and only whoever built the container knows which. Marketing is
     * the safer reading, and the CMS can lower it per entry.
     */
    const PROVIDER_CATEGORY = [
        'gtm'                 => 'marketing',
        'posthog'             => 'analytics',
        'google-analytics'    => 'analytics',
        'google-analytics-v3' => 'analytics',
        'mixpanel'            => 'analytics',
        'segment'             => 'analytics',
        'amplitude'           => 'analytics',
        'hubspot'             => 'marketing',
        'fullstory'           => 'analytics',
        'customerio'          => 'marketing',
    ];

    /**
     * Providers the application can actually load.
     *
     * All but PostHog are official `analytics` plugins with a browser bundle,
     * loaded from a pinned CDN URL by static/js/analytics/analytics.js. This
     * list and that file's registry are the two halves of the same fact: a
     * provider here with no entry there saves and never renders, which is the
     * failure this list exists to prevent.
     *
     * Four published plugins are deliberately absent because their bundles do
     * not work standalone - aws-pinpoint, intercom and snowplow reference
     * things they do not ship, and simple-analytics publishes no browser build
     * at all. See src/knowledge/analytics-providers.md.
     */
    const PROVIDERS = [
        'gtm'                 => 'Google Tag Manager',
        'posthog'             => 'PostHog',
        'google-analytics'    => 'Google Analytics 4',
        'google-analytics-v3' => 'Google Analytics (Universal)',
        'mixpanel'            => 'Mixpanel',
        'segment'             => 'Segment',
        'amplitude'           => 'Amplitude',
        'hubspot'             => 'HubSpot',
        'fullstory'           => 'FullStory',
        'customerio'          => 'Customer.io',
    ];

    /**
     * Where an integration applies.
     *
     * Matched against the WEBSITE's APP_ENV, folded to one of these: the
     * application maps development/dev/local, and qa/staging/stage/acceptance/
     * uat/test, onto the first two; anything else is production.
     *
     * `qa` exists because without it "not development" means production, and a
     * staging site would load the client's production keys and fill their real
     * analytics with test traffic - data that looks legitimate and is not.
     */
    const ENVIRONMENTS = ['all', 'production', 'qa', 'development'];

    /**
     * Where the options for each provider are documented.
     *
     * Whoever fills in `config` needs to know what that provider's plugin
     * accepts, and that is not knowledge worth copying into this file - it
     * would go stale the first time upstream changed it. Link to the source
     * instead.
     *
     * PostHog is ours, so it points at PostHog's own SDK documentation.
     */
    const DOCS_INDEX = 'https://getanalytics.io/plugins/';

    const DOCS = [
        'gtm'                 => 'https://getanalytics.io/plugins/google-tag-manager/',
        'posthog'             => 'https://posthog.com/docs/libraries/js',
        'google-analytics'    => 'https://getanalytics.io/plugins/google-analytics/',
        'google-analytics-v3' => 'https://getanalytics.io/plugins/google-analytics-v3/',
        'mixpanel'            => 'https://getanalytics.io/plugins/mixpanel/',
        'segment'             => 'https://getanalytics.io/plugins/segment/',
        'amplitude'           => 'https://getanalytics.io/plugins/amplitude/',
        'hubspot'             => 'https://getanalytics.io/plugins/hubspot/',
        'fullstory'           => 'https://getanalytics.io/plugins/fullstory/',
        'customerio'          => 'https://getanalytics.io/plugins/customerio/',
    ];

    /**
     * Per-provider configuration rules.
     *
     *   fields   key => whether it is required
     *   pattern  key => a regex the value must match, when there is a
     *            meaningful one. A rejected valid key is worse than an
     *            accepted odd one, so only well-documented shapes are
     *            enforced; everything else relies on the character rules
     *            in sanitize().
     */
    const RULES = [
        // Keys are the ones each plugin documents, stored verbatim and handed
        // over untouched: no translation layer to drift out of step.
        'gtm' => [
            'fields'  => ['containerId' => true],
            'pattern' => ['containerId' => '/^GTM-[A-Z0-9]+$/'],
        ],
        'posthog' => [
            'fields'  => ['key' => true, 'host' => true],
            'pattern' => ['key' => '/^[A-Za-z0-9_-]{16,200}$/'],
        ],
        'google-analytics' => [
            'fields'  => ['measurementIds' => true],
            // Plural for a reason: the plugin iterates it. A lone string is
            // the easy mistake and it fails in silence, so it is wrapped.
            'list'    => ['measurementIds'],
        ],
        'google-analytics-v3' => [
            'fields'  => ['trackingId' => true],
            'pattern' => ['trackingId' => '/^UA-[0-9]+-[0-9]+$/'],
        ],
        'mixpanel'   => ['fields' => ['token' => true]],
        'segment'    => ['fields' => ['writeKey' => true]],
        'amplitude'  => ['fields' => ['apiKey' => true]],
        'hubspot'    => ['fields' => ['portalId' => true]],
        'fullstory'  => ['fields' => ['org' => true]],
        'customerio' => ['fields' => ['siteId' => true]],
    ];

    protected bool $modelsChecked = false;

    // ------------------------------------------------------------- install

    /**
     * Creates the collection if it is missing. A model that already exists is
     * left completely alone, fields included.
     */
    public function ensureModels(bool $force = false): void {

        if ($this->modelsChecked && !$force) {
            return;
        }

        $this->modelsChecked = true;

        $content = $this->app->module('content');

        if (!$content) {
            return;
        }

        $options = $this->providerOptions();

        $this->ensureConsentModel($content);

        if ($content->exists(self::MODEL)) {
            // The model is left alone - with one deliberate exception. The
            // provider list is derived from code, not from anything an editor
            // owns, so a release that adds a provider has to reach projects
            // that already have the model. Without this, the select would be
            // frozen at whatever shipped the day the project was created.
            $this->syncModel($options);
            return;
        }

        $content->createModel(self::MODEL, [
            'label'   => 'Analytics',
            'info'    => 'Third-party tracking integrations. These keys are public: they are served in the page to every visitor.',
            'type'    => 'collection',
            'group'   => 'Analytics',
            'preview' => ['provider', 'enabled'],
            'fields'  => [
                $this->field('provider', 'select', 'Provider', true, [
                    'opts' => ['options' => $options],
                    'info' => 'Only providers this site has a plugin for.',
                ]),
                $this->field('config', 'object', 'Configuration', true, [
                    'info' => 'The keys the provider documents, stored verbatim. GTM: {"containerId":"GTM-XXXXXX"} · PostHog: {"key":"phc_...","host":"https://us.i.posthog.com"} · Mixpanel: {"token":"..."} · Segment: {"writeKey":"..."}. Full options per provider: '.self::DOCS_INDEX,
                ]),
                $this->field('category', 'select', 'Consent category', false, [
                    'opts' => ['options' => ['', 'analytics', 'marketing']],
                    'info' => 'Which consent a visitor must give before this loads. Leave empty to use the provider\'s default - Google Tag Manager defaults to marketing, because a container can hold advertising tags and only you know whether yours does.',
                ]),
                $this->field('enabled', 'boolean', 'Enabled', false, [
                    'info' => 'Turn a provider off without losing its configuration.',
                ]),
                $this->field('environments', 'select', 'Applies to', true, [
                    'opts' => ['options' => self::ENVIRONMENTS],
                    'info' => 'Matched against the website\'s APP_ENV. qa covers staging, acceptance and uat. Keeps development and staging traffic out of a client\'s production account.',
                ]),
            ],
        ]);

        /*
         * Writing a model updates the database, but Content\Helper\Model caches
         * the registry under 'content.models' and only bypasses it when debug
         * is on. Without this rebuild the model is invisible on any non-debug
         * environment while sitting correct in the database.
         * See src/knowledge/cockpit-model-registry-cache.md.
         */
        try {
            $this->app->helper('content.model')->cache(true);
        } catch (\Throwable $e) {
            $this->log('model cache rebuild failed: '.$e->getMessage());
        }
    }

    /**
     * Creates the consent singleton if it is missing, and leaves an existing
     * one completely alone - copy included.
     *
     * The copy is the part an editor owns. Overwriting it on an upgrade would
     * replace a client's reviewed wording with our defaults, which for a legal
     * control is worse than leaving it stale.
     */
    protected function ensureConsentModel($content): void {

        if ($content->exists(self::CONSENT_MODEL)) {
            return;
        }

        $content->createModel(self::CONSENT_MODEL, [
            'label' => 'Cookie consent',
            'info'  => 'The cookie banner. Until this is enabled, no tracking loads at all - which is the safe default, not a bug.',
            'type'  => 'singleton',
            'group' => 'Analytics',
            'fields' => [
                $this->field('enabled', 'boolean', 'Ask for consent', false, [
                    'info' => 'Off means no banner AND no tracking. Analytics only loads once a visitor agrees, so leaving this off switches every provider off with it.',
                ]),
                $this->field('copyVersion', 'text', 'Copy version', false, [
                    'info' => 'An identifier for the wording below, stored with each visitor\'s choice so you can tell later which text they agreed to. Bump it when you change the meaning of the text, not for a typo. It does NOT re-ask anybody.',
                ]),

                $this->field('title', 'text', 'Banner title', false, ['group' => 'Banner', 'i18n' => true]),
                $this->field('body', 'textarea', 'Banner text', false, [
                    'group' => 'Banner',
                    'i18n'  => true,
                    'info'  => 'Say plainly what is collected and why. Plain text - no markup, because none is rendered.',
                ]),
                $this->field('acceptLabel', 'text', 'Accept all', false, ['group' => 'Banner', 'i18n' => true]),
                $this->field('rejectLabel', 'text', 'Reject all', false, ['group' => 'Banner', 'i18n' => true]),
                $this->field('prefsLabel', 'text', 'Preferences', false, ['group' => 'Banner', 'i18n' => true]),
                $this->field('saveLabel', 'text', 'Save choices', false, ['group' => 'Banner', 'i18n' => true]),

                $this->field('policyLabel', 'text', 'Policy link text', false, ['group' => 'Banner', 'i18n' => true]),
                $this->field('policyUrl', 'text', 'Policy link URL', false, [
                    'group' => 'Banner',
                    'info'  => 'Your privacy or cookie policy. Left empty, no link is shown - which most regulators expect you to have.',
                ]),

                $this->field('necessaryLabel', 'text', 'Necessary - label', false, ['group' => 'Categories', 'i18n' => true]),
                $this->field('necessaryDescription', 'text', 'Necessary - description', false, [
                    'group' => 'Categories',
                    'i18n'  => true,
                    'info'  => 'Shown as always on and not refusable, because it is what the site needs to work.',
                ]),
                $this->field('analyticsLabel', 'text', 'Analytics - label', false, ['group' => 'Categories', 'i18n' => true]),
                $this->field('analyticsDescription', 'text', 'Analytics - description', false, ['group' => 'Categories', 'i18n' => true]),
                $this->field('marketingLabel', 'text', 'Marketing - label', false, ['group' => 'Categories', 'i18n' => true]),
                $this->field('marketingDescription', 'text', 'Marketing - description', false, ['group' => 'Categories', 'i18n' => true]),
            ],
        ]);

        /*
         * Same registry cache as the collection: written to the database and
         * invisible without this on any environment with debug off.
         * See src/knowledge/cockpit-model-registry-cache.md.
         */
        try {
            $this->app->helper('content.model')->cache(true);
        } catch (\Throwable $e) {
            $this->log('consent model cache rebuild failed: '.$e->getMessage());
        }

        $this->seedConsentCopy($content);

        $this->log('created the '.self::CONSENT_MODEL.' singleton with Spanish copy; consent is off until an editor enables it');
    }

    /**
     * Writes the initial banner copy, once, when the singleton is first created.
     *
     * Without this the singleton is created empty, and an editor who simply
     * ticks "Ask for consent" publishes a banner in English on a Spanish site:
     * the application carries last-resort text so a legal notice never renders
     * a blank button, and last-resort text is all an empty singleton has.
     * Seeding real copy means ticking the box produces something publishable.
     *
     * Three things this deliberately does NOT do:
     *
     *   - it does not enable consent. Off stays the default, because the copy
     *     is ours and the decision to publish it is the site owner's.
     *   - it does not fill policyUrl. There is no value we could invent, and a
     *     wrong privacy-policy link is worse than a missing one.
     *   - it does not run for an existing singleton. It is called only from the
     *     branch that just created the model, so an upgrade never overwrites
     *     copy a client had reviewed.
     */
    protected function seedConsentCopy($content): void {

        $copy = [
            'enabled'     => false,
            // A date rather than a counter: this is what a visitor's stored
            // decision is stamped with, and a date is the version an editor can
            // actually recognise a year later.
            'copyVersion' => date('Y-m-d'),

            'title'       => 'Usamos cookies',
            'body'        => 'Utilizamos cookies para entender cómo se usa este sitio. Tú decides cuáles aceptar.',
            'acceptLabel' => 'Aceptar todo',
            'rejectLabel' => 'Rechazar todo',
            'prefsLabel'  => 'Preferencias',
            'saveLabel'   => 'Guardar mis preferencias',

            'policyLabel' => 'Política de privacidad',
            'policyUrl'   => '',

            'necessaryLabel'       => 'Necesarias',
            'necessaryDescription' => 'Imprescindibles para que el sitio funcione. Siempre activas.',
            'analyticsLabel'       => 'Analítica',
            'analyticsDescription' => 'Nos ayudan a entender qué páginas resultan útiles.',
            'marketingLabel'       => 'Marketing',
            'marketingDescription' => 'Se usan para medir y orientar la publicidad.',

            /*
             * Published, explicitly.
             *
             * saveItem() stores _state 0 - a draft - unless told otherwise, and
             * Cockpit's read API only ever serves published content. Seeded copy
             * left as a draft would be invisible to the website, so the banner
             * would fall back to the English text this method exists to avoid,
             * while looking perfectly filled in to whoever opened the editor.
             * The seoPages rows hit exactly this during the 0.48.0 rollout.
             */
            '_state' => 1,
        ];

        try {
            $content->saveItem(self::CONSENT_MODEL, $copy);
        } catch (\Throwable $e) {
            // Not fatal. An unseeded singleton still works; it just starts
            // empty, which is where this addon was before.
            $this->log('could not seed the consent copy: '.$e->getMessage());
        }
    }

    /**
     * The category an entry will actually require: the editor's override if
     * there is one, otherwise the provider's default.
     *
     * The browser resolves this the same way from its own copy of the mapping.
     * This one is for showing an editor what they are about to get.
     */
    public function effectiveCategory(array $item): string {

        $override = $this->selectValue($item['category'] ?? null);

        if (in_array($override, self::CATEGORIES, true) && $override !== 'necessary') {
            return $override;
        }

        $provider = $this->selectValue($item['provider'] ?? null);

        return self::PROVIDER_CATEGORY[$provider] ?? 'marketing';
    }

    /**
     * Is this entry's category the provider's default, or an editor's choice?
     * The admin screen says which, so an override is visible rather than
     * looking like the default it replaced.
     */
    public function categoryIsOverridden(array $item): bool {

        $override = $this->selectValue($item['category'] ?? null);

        return in_array($override, self::CATEGORIES, true) && $override !== 'necessary';
    }

    /**
     * The select's options, from the providers the application can load.
     */
    protected function providerOptions(): array {
        $options = [];

        foreach (self::PROVIDERS as $value => $label) {
            $options[] = ['value' => $value, 'label' => $label];
        }

        return $options;
    }

    /**
     * Brings the parts of an existing model that are derived from code up to
     * date, and nothing else.
     *
     * Two of them, and both for the same reason: they are facts about what the
     * application can do, not choices an editor made. The provider list, so a
     * release that adds a provider reaches a project created before it. And the
     * consent category field, so a project that installed this addon before
     * consent existed can override a category without being recreated.
     *
     * Everything else is left alone - labels, order, info text, anything
     * edited. Nothing is written when both already match, so the usual cost is
     * one comparison per admin load.
     */
    protected function syncModel(array $options): void {

        $content = $this->app->module('content');
        $model   = $content->model(self::MODEL);

        if (!$model || !isset($model['fields'])) {
            return;
        }

        $changed  = false;
        $hasCategory = false;

        foreach ($model['fields'] as $i => $field) {

            $name = $field['name'] ?? '';

            if ($name === 'category') {
                $hasCategory = true;
                continue;
            }

            if ($name !== 'provider') {
                continue;
            }

            if (($field['opts']['options'] ?? null) != $options) {
                $model['fields'][$i]['opts']['options'] = $options;
                $changed = true;
            }
        }

        if (!$hasCategory) {
            /*
             * Appended rather than inserted next to `provider`, where it
             * belongs visually. Inserting would reorder an editor's existing
             * fields, and a field in the wrong place is a smaller problem than
             * a model that shuffles itself on upgrade.
             */
            $model['fields'][] = $this->field('category', 'select', 'Consent category', false, [
                'opts' => ['options' => ['', 'analytics', 'marketing']],
                'info' => 'Which consent a visitor must give before this loads. Empty uses the provider default.',
            ]);
            $changed = true;
        }

        if (!$changed) {
            return;
        }

        try {
            $content->updateModel(self::MODEL, $model);
            $this->app->helper('content.model')->cache(true);
            $this->log('model brought up to date'.($hasCategory ? '' : ' (added the consent category field)'));
        } catch (\Throwable $e) {
            $this->log('could not update the model: '.$e->getMessage());
        }
    }

    protected function field(string $name, string $type, string $label, bool $required = false, array $extra = []): array {
        return array_merge([
            'name'     => $name,
            'type'     => $type,
            'label'    => $label,
            'info'     => '',
            'group'    => '',
            'i18n'     => false,
            'required' => $required,
            'multiple' => false,
            'meta'     => [],
            'opts'     => [],
        ], $extra);
    }

    // ---------------------------------------------------------- validation

    /**
     * Normalises and checks an entry before it is stored.
     *
     * Two independent defences, neither relying on the other: the character
     * rules here, and the fact that the application never interpolates these
     * values into JavaScript. Either alone would do; together a mistake in one
     * is not a vulnerability.
     */
    public function beforeSave(array &$item, bool $isUpdate): void {

        /*
         * Normalise, do not reject.
         *
         * Cockpit turns ANY uncaught exception from a save hook into
         * `{"error":"500","message":"system error"}` (index.php:156) - the
         * message never reaches the editor, and core's own validation has the
         * same fate. So refusing a save is refusing it silently, which reads as
         * a broken CMS rather than as "you typed the wrong key".
         *
         * Ordinary mistakes are therefore stored and reported on the Analytics
         * screen, where there is room to say what is wrong and link to the
         * provider's documentation. The site skips anything it cannot use, so a
         * wrong entry costs tracking, not correctness.
         *
         * Genuinely hostile input is still refused outright - see sanitize().
         */
        $provider    = $this->selectValue($item['provider'] ?? null);
        $environment = $this->selectValue($item['environments'] ?? null) ?: 'all';

        $item['provider']     = $provider;
        $item['environments'] = in_array($environment, self::ENVIRONMENTS, true) ? $environment : 'all';

        /*
         * The category override, normalised to empty when it is not one this
         * addon knows. Empty means "use the provider's default", which is the
         * fail-closed reading: a value we do not recognise must not become a
         * category the browser then fails to match, silently blocking a
         * provider the editor believed they had allowed.
         *
         * `necessary` is refused as an override on purpose. It is the one
         * category a visitor cannot decline, so letting an entry claim it
         * would be a way to load tracking without consent - the exact thing
         * this mechanism exists to prevent.
         */
        $category = $this->selectValue($item['category'] ?? null);

        $item['category'] = ($category !== 'necessary' && in_array($category, self::CATEGORIES, true))
            ? $category
            : '';

        $config = is_array($item['config'] ?? null) ? $item['config'] : [];
        $lists  = self::RULES[$provider]['list'] ?? [];

        foreach ($config as $key => $value) {

            if (is_string($value)) {
                $value = trim($value);
                $this->sanitize((string)$key, $value);
            }

            // Options the plugin iterates must be lists. Typing one value into
            // a plural field is the obvious thing to do and it fails silently,
            // so a scalar is wrapped rather than left to break later.
            if (in_array($key, $lists, true) && !is_array($value)) {
                $value = ($value === '' || $value === null) ? [] : [$value];
            }

            $config[$key] = $value;
        }

        $item['config'] = $config;
    }

    /**
     * What is wrong with an entry, in words an editor can act on.
     *
     * Empty means it is usable. This is the same knowledge validation used to
     * throw, moved to where it can actually be read.
     */
    public function problems(array $item): array {

        $provider = $this->selectValue($item['provider'] ?? null);
        $config   = is_array($item['config'] ?? null) ? $item['config'] : [];
        $problems = [];

        if ($provider === '') {
            return $this->hasValues($config) ? ['No provider selected.'] : ['Not configured yet.'];
        }

        if (!isset(self::PROVIDERS[$provider])) {
            $problems[] = "\"{$provider}\" is not a provider this site can load.";
            return $problems;
        }

        $rules = self::RULES[$provider] ?? ['fields' => [], 'pattern' => []];

        foreach ($rules['fields'] as $key => $required) {

            $value = $config[$key] ?? null;

            if (is_array($value)) {
                $value = array_filter($value, fn($v) => $v !== '' && $v !== null);
                if (!count($value) && $required) {
                    $problems[] = "Missing \"{$key}\".";
                }
                continue;
            }

            if (($value === null || $value === '') && $required) {
                $problems[] = "Missing \"{$key}\".";
                continue;
            }

            if (is_string($value) && isset($rules['pattern'][$key]) && !preg_match($rules['pattern'][$key], $value)) {
                $problems[] = "\"{$key}\" does not look right: ".$this->describe($provider, $key);
            }
        }

        // Keys that belong to a different provider are the most common mistake
        // and the least obvious, so name them rather than ignoring them.
        $unknown = array_diff(array_keys($config), array_keys($rules['fields']));

        if (count($unknown) && count($rules['fields'])) {
            $problems[] = 'Unused here: '.implode(', ', $unknown).'. '
                .self::PROVIDERS[$provider].' expects '.implode(', ', array_keys($rules['fields'])).'.';
        }

        return $problems;
    }

    /**
     * Is this entry complete enough for the site to load it?
     */
    public function isUsable(array $item): bool {
        return count($this->problems($item)) === 0;
    }

    /**
     * The empty configuration each provider expects, for the editor to
     * pre-fill when a provider is chosen.
     *
     * Derived from the same RULES the screen validates against, so the shape
     * offered and the shape checked cannot drift apart.
     */
    public function configTemplates(): array {

        $templates = [];

        foreach (array_keys(self::PROVIDERS) as $provider) {

            $skeleton = [];

            $lists = self::RULES[$provider]['list'] ?? [];

            foreach (array_keys(self::RULES[$provider]['fields'] ?? []) as $key) {
                // Offer a list where the plugin wants one, so the shape is
                // obvious before anything is typed.
                $skeleton[$key] = in_array($key, $lists, true) ? [''] : '';
            }

            $templates[$provider] = $skeleton;
        }

        // A hint of what a valid value looks like, where the shape is
        // distinctive enough to be worth showing.
        $templates['gtm']['containerId']                  = 'GTM-';
        $templates['google-analytics-v3']['trackingId']   = 'UA-';
        $templates['posthog']['host']                     = 'https://us.i.posthog.com';

        return $templates;
    }

    /**
     * The scalar behind a select field.
     *
     * Cockpit's select always emits an array, even for a single choice, so
     * this folds ["posthog"] and "posthog" to the same thing. Getting this
     * wrong cast an array to the string "Array" and refused every save the
     * editor made.
     */
    protected function selectValue($value): string {

        if (is_array($value)) {
            $value = $value[0] ?? '';
        }

        return is_string($value) ? trim($value) : '';
    }

    /**
     * Does this configuration hold anything at all? Used to tell an untouched
     * draft from a half-filled one.
     */
    protected function hasValues($config): bool {

        if (!is_array($config)) {
            return $config !== '' && $config !== null;
        }

        foreach ($config as $v) {
            if ($v !== '' && $v !== null && $v !== []) {
                return true;
            }
        }

        return false;
    }

    /**
     * Characters that have no business in any of these values, refused
     * regardless of provider.
     */
    protected function sanitize(string $key, string $value): void {
        // The one thing still refused outright. It costs an opaque 500, which
        // is a bad experience - but this is not an ordinary typo, it is input
        // that has no business in a page, and storing it to report politely
        // later is the wrong trade.
        if (preg_match('/["\'<>\\\\`]/', $value)) {
            throw new \App\Exception\AppNotification(
                "\"{$key}\" contains characters that are not allowed here: quotes, angle brackets or backslashes."
            );
        }
    }

    protected function describe(string $provider, string $key): string {
        if ($provider === 'gtm' && $key === 'containerId') {
            return 'a container id like GTM-ABC1234.';
        }
        if ($provider === 'google-analytics-v3' && $key === 'trackingId') {
            return 'a tracking id like UA-123456-1.';
        }
        if ($provider === 'posthog' && $key === 'key') {
            return 'a project API key, usually starting with phc_.';
        }
        return 'see the addon README.';
    }

    // ------------------------------------------------------------- reading

    /**
     * Every integration, for the admin screen. Includes disabled and broken
     * ones - seeing a broken entry is the whole point of that screen.
     */
    public function all(): array {
        return $this->app->module('content')->items(self::MODEL, [
            'sort' => ['provider' => 1],
        ]) ?: [];
    }

    /**
     * The consent singleton, or an empty array when it does not exist yet.
     *
     * Read for the admin screen only. The website reads it through the core
     * REST API like everything else, and nothing here decides what a visitor
     * is allowed - that is the browser's, from a cookie the server never sees.
     */
    public function consent(): array {

        $content = $this->app->module('content');

        if (!$content || !$content->exists(self::CONSENT_MODEL)) {
            return [];
        }

        // The empty filter is required: Content's item() takes one, and the
        // Webapp addon reads its own singleton the same way.
        return $content->item(self::CONSENT_MODEL, []) ?: [];
    }

    public function providerLabel(string $provider): string {
        return self::PROVIDERS[$provider] ?? $provider;
    }

    public function providerDocs(string $provider): string {
        return self::DOCS[$provider] ?? self::DOCS_INDEX;
    }

    /**
     * Provider, the keys it needs, and where its options are documented - for
     * the admin screen's reference table.
     */
    public function providerReference(): array {
        $rows = [];

        foreach (self::PROVIDERS as $value => $label) {

            $fields = array_keys(self::RULES[$value]['fields'] ?? []);

            $rows[] = [
                'provider' => $value,
                'label'    => $label,
                'keys'     => $fields,
                'docs'     => $this->providerDocs($value),
                'custom'   => $value === 'posthog',
            ];
        }

        return $rows;
    }

    protected function log(string $message): void {
        error_log('[analytics] '.$message);
    }
}
