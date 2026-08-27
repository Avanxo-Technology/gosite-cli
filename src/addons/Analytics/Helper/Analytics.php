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
     * Providers the application has a plugin for.
     *
     * Adding one here without adding its plugin produces an entry that saves
     * and never renders, which is the failure this list exists to prevent.
     * Keep it in step with static/js/analytics/.
     */
    const PROVIDERS = [
        'gtm'     => 'Google Tag Manager',
        'posthog' => 'PostHog',
    ];

    const ENVIRONMENTS = ['all', 'production', 'development'];

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
        'gtm' => [
            'fields'  => ['id' => true],
            'pattern' => ['id' => '/^GTM-[A-Z0-9]+$/'],
        ],
        'posthog' => [
            'fields'  => ['key' => true, 'host' => true],
            'pattern' => ['key' => '/^[A-Za-z0-9_-]{16,200}$/'],
        ],
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

        if (!$content || $content->exists(self::MODEL)) {
            return;
        }

        $options = [];

        foreach (self::PROVIDERS as $value => $label) {
            $options[] = ['value' => $value, 'label' => $label];
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
                    'info' => 'GTM: {"id":"GTM-XXXXXX"} · PostHog: {"key":"...","host":"https://us.i.posthog.com"}',
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
        if ($provider === 'gtm' && $key === 'id') {
            return 'a container id like GTM-ABC1234.';
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

    protected function log(string $message): void {
        error_log('[analytics] '.$message);
    }
}
