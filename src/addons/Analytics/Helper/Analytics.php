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

    const ENVIRONMENTS = ['all', 'production', 'development'];

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

        if ($content->exists(self::MODEL)) {
            // The model is left alone - with one deliberate exception. The
            // provider list is derived from code, not from anything an editor
            // owns, so a release that adds a provider has to reach projects
            // that already have the model. Without this, the select would be
            // frozen at whatever shipped the day the project was created.
            $this->syncProviderOptions($options);
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
                $this->field('enabled', 'boolean', 'Enabled', false, [
                    'info' => 'Turn a provider off without losing its configuration.',
                ]),
                $this->field('environments', 'select', 'Applies to', true, [
                    'opts' => ['options' => self::ENVIRONMENTS],
                    'info' => 'Keep development traffic out of a client\'s production account.',
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
     * Brings an existing model's provider list up to date, and nothing else.
     *
     * Narrow on purpose: only the options of the `provider` field are
     * rewritten. Labels, other fields, anything an editor changed - untouched.
     * Nothing is written when the list already matches, so this costs one
     * comparison per admin load rather than a write.
     */
    protected function syncProviderOptions(array $options): void {

        $content = $this->app->module('content');
        $model   = $content->model(self::MODEL);

        if (!$model || !isset($model['fields'])) {
            return;
        }

        $changed = false;

        foreach ($model['fields'] as $i => $field) {

            if (($field['name'] ?? '') !== 'provider') {
                continue;
            }

            if (($field['opts']['options'] ?? null) == $options) {
                return;
            }

            $model['fields'][$i]['opts']['options'] = $options;
            $changed = true;
            break;
        }

        if (!$changed) {
            return;
        }

        try {
            $content->updateModel(self::MODEL, $model);
            $this->app->helper('content.model')->cache(true);
            $this->log('provider list updated to: '.implode(', ', array_keys(self::PROVIDERS)));
        } catch (\Throwable $e) {
            $this->log('could not update the provider list: '.$e->getMessage());
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

        $provider = (string)($item['provider'] ?? '');

        if (!isset(self::PROVIDERS[$provider])) {
            throw new \App\Exception\AppNotification(
                "\"{$provider}\" is not a provider this site can render. Known: ".implode(', ', array_keys(self::PROVIDERS)).'.'
            );
        }

        $environment = (string)($item['environments'] ?? 'all');

        if (!in_array($environment, self::ENVIRONMENTS, true)) {
            throw new \App\Exception\AppNotification(
                "\"{$environment}\" is not a known environment. Use: ".implode(', ', self::ENVIRONMENTS).'.'
            );
        }

        $item['environments'] = $environment;

        $config = $item['config'] ?? [];

        if (!is_array($config)) {
            throw new \App\Exception\AppNotification('Configuration must be an object.');
        }

        $rules = self::RULES[$provider] ?? ['fields' => [], 'pattern' => []];

        foreach ($rules['fields'] as $key => $required) {

            $value = $config[$key] ?? null;

            if ($value === null || $value === '') {
                if ($required) {
                    throw new \App\Exception\AppNotification("{$provider} needs a \"{$key}\" value.");
                }
                continue;
            }

            if (!is_string($value)) {
                throw new \App\Exception\AppNotification("\"{$key}\" must be text.");
            }

            $value = trim($value);
            $this->sanitize($key, $value);

            if (isset($rules['pattern'][$key]) && !preg_match($rules['pattern'][$key], $value)) {
                throw new \App\Exception\AppNotification(
                    "\"{$key}\" does not look like a valid {$provider} value: {$this->describe($provider, $key)}"
                );
            }

            $config[$key] = $value;
        }

        // Keys not declared for this provider are dropped rather than stored:
        // the application will not read them, so keeping them only invites
        // someone to believe they do something.
        $item['config'] = array_intersect_key($config, $rules['fields']);
    }

    /**
     * Characters that have no business in any of these values, refused
     * regardless of provider.
     */
    protected function sanitize(string $key, string $value): void {
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
     * Every integration, for the admin screen. Includes disabled ones.
     */
    public function all(): array {
        return $this->app->module('content')->items(self::MODEL, [
            'sort' => ['provider' => 1],
        ]) ?: [];
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
