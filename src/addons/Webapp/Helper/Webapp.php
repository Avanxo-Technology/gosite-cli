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
    public function purge($model = null, $item = null): void {

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
        $token    = getenv('COCKPIT_API_TOKEN') ?: '';

        $id = is_array($item) ? ($item['_id'] ?? null) : $item;

        $body = json_encode(array_filter([
            'model' => $model ? (string)$model : null,
            'id'    => $id ? (string)$id : null,
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
