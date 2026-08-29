<?php

namespace Webapp\Helper;

/**
 * Webapp business logic.
 *
 * Manages the webapp singleton (SEO configuration) and the seoPages
 * collection (per-page SEO overrides). Also absorbs the functionality of
 * six infrastructure addons: AssetPathFix, AssetsUpload, StarterContent,
 * CachePurge, CloudStorage, ModelManager.
 */
class Webapp extends \Lime\Helper {

    const MODEL_WEBAPP   = 'webapp';
    const MODEL_SEO_PAGES = 'seoPages';
    const MODEL_HOME     = 'home';

    protected bool $modelsChecked = false;

    // ------------------------------------------------------------- install

    /**
     * Creates the webapp singleton and seoPages collection if they are missing.
     * Also creates the home singleton (from StarterContent) if missing.
     *
     * Called on admin init, so a fresh install needs no manual setup.
     */
    public function ensureModels(bool $force = false): void {

        if ($this->modelsChecked && !$force) {
            return;
        }

        $this->modelsChecked = true;

        $content = $this->app->module('content');

        if (!$content) return;

        $created = false;

        // Webapp singleton (SEO configuration)
        if (!$content->exists(self::MODEL_WEBAPP)) {
            $content->createModel(self::MODEL_WEBAPP, [
                'label'   => 'Webapp',
                'info'    => 'Site-wide SEO configuration: favicon, default meta tags, robots.txt, and LLM content.',
                'type'    => 'singleton',
                'group'   => 'Webapp',
                'fields'  => [
                    $this->field('favicon', 'asset', 'Favicon'),
                    $this->field('siteName', 'text', 'Site Name', false, [
                        'info' => 'Brand/site name, used for og:site_name and JSON-LD organization markup.',
                    ]),
                    $this->field('siteUrl', 'text', 'Site URL', false, [
                        'info' => 'Public origin of the site, e.g. "https://example.com" (no trailing slash). Used to build canonical URLs, og:url and sitemap.xml.',
                    ]),
                    // Plain text on purpose: this is served verbatim to LLM
                    // crawlers, so a wysiwyg's <p> wrappers would end up in the
                    // output.
                    $this->field('llmText', 'text', 'LLM Text', false, [
                        'info' => 'Content served to LLM crawlers and AI assistants. Plain text, no formatting. Describe your site, its purpose, and key information.',
                        'opts' => ['multiline' => true, 'height' => '260px'],
                    ]),
                    $this->field('robotsTxt', 'code', 'Robots.txt', false, [
                        'info' => 'Full content of /robots.txt. One rule per line.',
                    ]),
                    $this->field('defaultTitle', 'text', 'Default Title', false, [
                        'info' => 'Used as fallback when a page has no specific title.',
                    ]),
                    $this->field('defaultDescription', 'text', 'Default Description', false, [
                        'info' => 'Used as fallback meta description when a page has none.',
                    ]),
                    $this->field('defaultImage', 'asset', 'Default Image', false, [
                        'info' => 'Used as fallback OG image when a page has none.',
                    ]),
                    $this->field('language', 'text', 'Language', false, [
                        'info' => 'BCP-47 language tag, e.g. "es-ES" or "en". Sets <html lang> and og:locale. Defaults to "en" when empty.',
                    ]),
                    $this->field('author', 'text', 'Author', false, [
                        'info' => 'Name behind the content, emitted as <meta name="author">.',
                    ]),
                    $this->field('publisher', 'text', 'Publisher', false, [
                        'info' => 'Organization that publishes the site. Emitted as a schema.org Organization inside the JSON-LD, which is the form search engines actually read.',
                    ]),
                    $this->field('publisherLogo', 'asset', 'Publisher Logo', false, [
                        'info' => 'Logo for the publisher Organization in the JSON-LD.',
                    ]),
                    $this->field('twitterHandle', 'text', 'X / Twitter Handle', false, [
                        'info' => 'Handle with or without the @, e.g. "@example". Emitted as twitter:site and twitter:creator. Leave empty to omit both.',
                    ]),
                    $this->field('jsonLd', 'code', 'JSON-LD', false, [
                        'info' => 'Site-wide structured data (schema.org). Leave empty and the app emits a minimal WebSite/Organization block built from Site Name, Site URL and Default Image.',
                    ]),
                ],
            ]);
            $created = true;
        }

        // SEO Pages collection (per-page overrides)
        if (!$content->exists(self::MODEL_SEO_PAGES)) {
            $content->createModel(self::MODEL_SEO_PAGES, [
                'label'   => 'SEO Pages',
                'info'    => 'Per-page SEO overrides. Match by path (e.g. "/about", "/pricing").',
                'type'    => 'collection',
                'group'   => 'Webapp',
                'preview' => ['path', 'title'],
                'fields'  => [
                    $this->field('path', 'text', 'Path', true, [
                        'info' => 'URL path including leading slash, e.g. "/about".',
                    ]),
                    $this->field('title', 'text', 'Title'),
                    $this->field('description', 'text', 'Description'),
                    $this->field('image', 'asset', 'Image'),
                    $this->field('jsonLd', 'code', 'JSON-LD', false, [
                        'info' => 'Structured data for search engines (schema.org). Paste valid JSON.',
                    ]),
                    $this->field('canonical', 'text', 'Canonical URL', false, [
                        'info' => 'Override the canonical URL. Leave empty to use the page path.',
                    ]),
                    $this->field('noIndex', 'boolean', 'No Index', false, [
                        'info' => 'If set, search engines will not index this page.',
                    ]),
                ],
            ]);
            $created = true;
        }

        // Home singleton (from StarterContent)
        if (!$content->exists(self::MODEL_HOME)) {
            $content->createModel(self::MODEL_HOME, [
                'label'   => 'Home',
                'info'    => 'Front page content. The generated application reads this singleton.',
                'type'    => 'singleton',
                'fields'  => [
                    $this->field('headline', 'text', 'Headline'),
                    $this->field('intro', 'wysiwyg', 'Intro'),
                ],
            ]);
            $created = true;
        }

        // Migrations for installs created before a field definition changed.
        $migrated = $this->migrateModels($content);

        if ($created || $migrated) {
            try {
                $this->app->helper('content.model')->cache(true);
            } catch (\Throwable $e) {
                $this->log('model cache rebuild failed: '.$e->getMessage());
            }
        }
    }

    /**
     * Brings already-created models up to the current field definitions.
     *
     * ensureModels() only creates what is missing, so a project scaffolded
     * before a field changed keeps the old definition forever. Each migration
     * here must be idempotent and must leave stored entries alone.
     */
    protected function migrateModels($content): bool {

        $changed = false;

        // llmText used to be a wysiwyg. Its output is served verbatim to LLM
        // crawlers, so the editor must produce plain text, not <p>-wrapped HTML.
        if ($content->exists(self::MODEL_WEBAPP)) {

            $model  = $content->model(self::MODEL_WEBAPP);
            $fields = $model['fields'] ?? [];
            $touched = false;

            foreach ($fields as $i => $field) {

                if (($field['name'] ?? '') !== 'llmText') continue;
                if (($field['type'] ?? '') !== 'wysiwyg') continue;

                $fields[$i]['type'] = 'text';
                $fields[$i]['opts'] = array_merge($field['opts'] ?? [], [
                    'multiline' => true,
                    'height'    => '260px',
                ]);
                $touched = true;
                $this->log('migrated llmText from wysiwyg to plain text');
            }

            // Fields added after the model shipped. Appended, never reordered,
            // so an editor's existing layout is left as it was.
            $names = array_column($fields, 'name');

            $additions = [
                'siteUrl' => $this->field('siteUrl', 'text', 'Site URL', false, [
                    'info' => 'Public origin of the site, e.g. "https://example.com" (no trailing slash). Used to build canonical URLs, og:url and sitemap.xml.',
                ]),
                'jsonLd' => $this->field('jsonLd', 'code', 'JSON-LD', false, [
                    'info' => 'Site-wide structured data (schema.org). Leave empty and the app emits a minimal WebSite/Organization block built from Site Name, Site URL and Default Image.',
                ]),
                'language' => $this->field('language', 'text', 'Language', false, [
                    'info' => 'BCP-47 language tag, e.g. "es-ES" or "en". Sets <html lang> and og:locale. Defaults to "en" when empty.',
                ]),
                'author' => $this->field('author', 'text', 'Author', false, [
                    'info' => 'Name behind the content, emitted as <meta name="author">.',
                ]),
                'publisher' => $this->field('publisher', 'text', 'Publisher', false, [
                    'info' => 'Organization that publishes the site. Emitted as a schema.org Organization inside the JSON-LD, which is the form search engines actually read.',
                ]),
                'publisherLogo' => $this->field('publisherLogo', 'asset', 'Publisher Logo', false, [
                    'info' => 'Logo for the publisher Organization in the JSON-LD.',
                ]),
                'twitterHandle' => $this->field('twitterHandle', 'text', 'X / Twitter Handle', false, [
                    'info' => 'Handle with or without the @, e.g. "@example". Emitted as twitter:site and twitter:creator. Leave empty to omit both.',
                ]),
            ];

            foreach ($additions as $name => $definition) {
                if (in_array($name, $names, true)) continue;
                $fields[] = $definition;
                $touched = true;
                $this->log("added missing field {$name} to the webapp model");
            }

            if ($touched) {
                try {
                    $content->updateModel(self::MODEL_WEBAPP, ['fields' => $fields]);
                    $changed = true;
                } catch (\Throwable $e) {
                    $this->log('webapp model migration failed: '.$e->getMessage());
                }
            }
        }

        return $changed;
    }

    // ---------------------------------------------------------------- config

    /**
     * Reads a key from the webapp singleton.
     */
    public function config(string $key, $default = null) {

        $content = $this->app->module('content');

        if (!$content) return $default;

        $item = $content->item(self::MODEL_WEBAPP, []);

        if (!$item) return $default;

        return $item[$key] ?? $default;
    }

    /**
     * Returns the full webapp singleton as an array.
     */
    /**
     * Returns the webapp model's field definitions, in editor order.
     *
     * The admin screen renders one row per entry rather than a fixed list, so
     * a field added to the model shows up on the screen without anyone having
     * to remember to touch the view.
     */
    public function webappFields(): array {

        $content = $this->app->module('content');

        if (!$content || !$content->exists(self::MODEL_WEBAPP)) {
            return [];
        }

        $model = $content->model(self::MODEL_WEBAPP);

        return $model['fields'] ?? [];
    }

    public function getWebappConfig(): array {

        $content = $this->app->module('content');

        if (!$content) return [];

        return $content->item(self::MODEL_WEBAPP, []) ?: [];
    }

    // ------------------------------------------------------------- seo pages

    /**
     * Finds an SEO page entry by path.
     */
    public function findSeoPage(string $path): ?array {

        $content = $this->app->module('content');

        if (!$content) return null;

        return $content->item(self::MODEL_SEO_PAGES, ['path' => $path]) ?: null;
    }

    /**
     * Lists all SEO page entries.
     */
    public function seoPages(): array {

        $content = $this->app->module('content');

        if (!$content) return [];

        return $content->items(self::MODEL_SEO_PAGES, [
            'sort' => ['path' => 1],
        ]) ?: [];
    }

    /**
     * Saves an SEO page entry.
     */
    public function saveSeoPage(array $item): array {

        $content = $this->app->module('content');

        if (!$content) {
            throw new \RuntimeException('Content module not available');
        }

        $id = $item['_id'] ?? null;

        if ($id) {
            $content->saveItem(self::MODEL_SEO_PAGES, $item, $id);
        } else {
            $item['_id'] = $content->saveItem(self::MODEL_SEO_PAGES, $item);
        }

        return $item;
    }

    /**
     * Removes an SEO page entry.
     */
    public function removeSeoPage(string $id): bool {

        $content = $this->app->module('content');

        if (!$content) return false;

        $content->removeItem(self::MODEL_SEO_PAGES, $id);

        return true;
    }

    // ----------------------------------------------------------------- purge

    /**
     * POSTs to the Go app's cache-purge endpoint.
     *
     * Absorbed from CachePurge addon. Called on content.item.save and
     * exposed as $app->helper('cachepurge') for Replica.
     */
    /**
     * Makes sure COCKPIT_API_TOKEN is a registered API key.
     *
     * The application authenticates with this token on every read. Locally
     * `gosite start` seeds it straight into Mongo, but nothing does that on a
     * deployed site - Coolify never runs the CLI - so the key exists there only
     * if somebody created it by hand in the admin.
     *
     * That gap stayed invisible because Cockpit caches the key registry in
     * memory: the site kept working from a snapshot taken when the key did
     * exist. The first cache flush cleared it, the rebuild found nothing, and
     * every API read answered `412 {"error":"Authentication failed"}` - not
     * just until the CMS warmed up, but permanently, because an empty registry
     * is cached as a value rather than as a miss.
     *
     * Seeding it here is the same key, the same role and the same upsert
     * `gosite start` performs; it just also happens where the CLI cannot reach.
     *
     * Returns true when it had to create the key.
     */
    public function ensureApiKey(): bool {

        $token = trim((string)getenv('COCKPIT_API_TOKEN'));

        if ($token === '') {
            return false;
        }

        try {
            $existing = $this->app->dataStorage->findOne('system/api_keys', ['key' => $token]);

            if ($existing) {
                return false;
            }

            // save() takes its data by reference, so this cannot be a literal.
            $entry = [
                'name'   => 'gosite-seed',
                'key'    => $token,
                'role'   => 'admin',
                'active' => true,
            ];

            $this->app->dataStorage->save('system/api_keys', $entry);

            // The registry the API gate reads is a cache of that collection, so
            // the new key is invisible until it is rebuilt.
            $this->app->helper('api')->cache(true);

            // Deliberately not logging the token itself.
            $this->log('registered the application API key (it was missing)');

            return true;

        } catch (\Throwable $e) {
            $this->log('could not register the application API key: '.$e->getMessage());
            return false;
        }
    }

    /**
     * Rebuilds what a Cockpit cache flush just wiped, so the next read finds a
     * warm CMS instead of an empty one.
     *
     * The flush clears #cache: and #tmp: and empties app memory. The model
     * registry lives in that cache, so until it is rebuilt Cockpit answers 404
     * for every model - and the application, told to purge at the same moment,
     * re-renders against a CMS that reports no content and serves an error
     * page instead. See src/knowledge/cockpit-cold-render-502.md.
     *
     * Returns what it managed to warm, for the log line.
     */
    public function warmCockpit(): array {

        $warmed = [];

        // The API key registry first: until it is back, every read the
        // application makes answers 412 and nothing else matters.
        $this->ensureApiKey();

        try {
            $keys = $this->app->helper('api')->cache(true);
            $warmed['apiKeys'] = count($keys);
        } catch (\Throwable $e) {
            $this->log('cache flush: api key rebuild failed: '.$e->getMessage());
        }

        try {
            $models = $this->app->helper('content.model')->cache(true);
            $warmed['models'] = count($models);
        } catch (\Throwable $e) {
            $this->log('cache flush: model registry rebuild failed: '.$e->getMessage());
        }

        // Read one real item as well: it opens the database connection and
        // repopulates memory, so the application's first call is not the one
        // paying for the cold start.
        try {
            $content = $this->app->module('content');
            if ($content && $content->exists(self::MODEL_WEBAPP)) {
                $content->item(self::MODEL_WEBAPP, []);
                $warmed['singleton'] = self::MODEL_WEBAPP;
            }
        } catch (\Throwable $e) {
            $this->log('cache flush: singleton warm failed: '.$e->getMessage());
        }

        return $warmed;
    }

    public function purge($model = null, $item = null, ?string $scope = null): void {

        static $disabledLogged = false;

        $url = getenv('APP_URL');

        if (!$url) {
            if (!$disabledLogged) {
                $disabledLogged = true;
                error_log('[webapp/cachepurge] disabled: APP_URL is not set.');
            }
            return;
        }

        $endpoint = rtrim($url, '/') . '/cache/purge';

        // Trimmed on purpose: a secret pasted into a deployment UI often
        // arrives with a trailing newline, and the application compares the
        // header byte for byte - the result is a 401 while both sides look
        // identical to a human reading the dashboard.
        $token = trim((string)getenv('COCKPIT_API_TOKEN'));

        $id = is_array($item) ? ($item['_id'] ?? null) : $item;

        // scope lets the CMS say "everything" when there is no single model to
        // name - a full cache flush, where no cached page can be trusted.
        $body = json_encode(array_filter([
            'model' => $model ? (string)$model : null,
            'id'    => $id ? (string)$id : null,
            'scope' => $scope ?: null,
        ], fn($v) => $v !== null));

        $headers = ['Content-Type: application/json'];

        if ($token) {
            $headers[] = 'X-Api-Key: ' . $token;
        }

        $ch = curl_init($endpoint);
        curl_setopt_array($ch, [
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => $body,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 5,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_HTTPHEADER     => $headers,
        ]);
        curl_exec($ch);

        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error  = curl_error($ch);

        curl_close($ch);

        if ($error !== '') {
            error_log("[webapp/cachepurge] {$endpoint} transport error: {$error}");
        } elseif ($status === 401) {
            // Say which half is wrong. Without this the log states the obvious
            // and hides the one fact that resolves it.
            $detail = $token === ''
                ? 'this CMS has no COCKPIT_API_TOKEN, so no X-Api-Key was sent'
                : 'the token this CMS sent does not match the application\'s COCKPIT_API_TOKEN';
            error_log("[webapp/cachepurge] {$endpoint} refused the purge (401): {$detail}");
        } elseif ($status < 200 || $status >= 300) {
            error_log("[webapp/cachepurge] {$endpoint} failed with HTTP {$status}");
        }
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Field definition in the exact shape the Content module stores.
     */
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

    protected function log(string $message): void {
        error_log('[webapp] '.$message);
    }
}
