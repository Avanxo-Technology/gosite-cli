<?php

namespace Blog\Helper;

/**
 * All Blog business logic.
 *
 * Articles live in ordinary Cockpit Content collections, so authoring happens
 * in Cockpit's own editor exactly like any other content. This addon adds what
 * the core cannot: the model set every gosite site shares, slug rules, a byline
 * that falls back to the editing user, and an admin screen that links into the
 * real public site.
 *
 * Nothing here serves content to visitors. The public pages are rendered by the
 * Go application, which reads the collections through the core REST API.
 */
class Blog extends \Lime\Helper {

    const MODEL_BLOGS      = 'blogs';
    const MODEL_POSTS      = 'blogPosts';
    const MODEL_CATEGORIES = 'blogCategories';
    const MODEL_AUTHORS    = 'blogAuthors';

    /**
     * Paths the gosite scaffold already serves. A blog slug sits at the root of
     * the site (`/{blog}`), so one of these as a slug would be unreachable -
     * echo resolves a static segment before `:blog`. Refused at save time.
     */
    const RESERVED_SLUGS = ['static', 'storage', 'healthz', 'cache', 'api', 'admin'];

    protected bool $modelsChecked = false;

    // -------------------------------------------------------------- config

    /**
     * Reads a key from the `blog` block of cockpit/config.php.
     *
     * bootstrap.php builds the app with `new Lime\App($config)`, so the file's
     * top-level keys land at the ROOT of the registry - `blog/...`, not
     * `config/blog/...`. Getting this wrong left the whole Forms config block
     * inert for several releases (fixed in gosite 0.43.1); the nested path is
     * kept as a fallback in case a Cockpit build does nest the config.
     */
    public function config(string $key, $default = null) {

        $value = $this->app->retrieve("blog/{$key}", null);

        if ($value !== null) {
            return $value;
        }

        return $this->app->retrieve("config/blog/{$key}", $default);
    }

    /**
     * Public base URL of the Go site, used to build preview links.
     *
     * Empty when unconfigured - the admin screen degrades to saying preview is
     * unavailable rather than emitting broken links.
     */
    public function siteUrl(): string {
        $url = (string)($this->config('site_url') ?: getenv('SITE_URL') ?: '');
        return rtrim($url, '/');
    }

    // ------------------------------------------------------------- install

    /**
     * Creates the four content models if they are missing.
     *
     * Called on admin init, so a fresh install needs no manual setup. A model
     * that already exists is left completely alone - including its fields.
     */
    public function ensureModels(bool $force = false): void {

        if ($this->modelsChecked && !$force) {
            return;
        }

        $this->modelsChecked = true;

        $content = $this->app->module('content');

        if (!$content) return;

        $created = false;

        if (!$content->exists(self::MODEL_BLOGS)) {
            $content->createModel(self::MODEL_BLOGS, [
                'label'   => 'Blogs',
                'info'    => 'One entry per blog. The slug is the first segment of the public URL.',
                'type'    => 'collection',
                'group'   => 'Blog',
                'preview' => ['title', 'slug'],
                'fields'  => [
                    $this->field('title', 'text', 'Title', true),
                    $this->field('slug', 'text', 'Slug', true, ['info' => 'URL segment, e.g. "noticias" for /noticias']),
                    $this->field('description', 'text', 'Description'),
                ],
            ]);
            $created = true;
        }

        if (!$content->exists(self::MODEL_CATEGORIES)) {
            $content->createModel(self::MODEL_CATEGORIES, [
                'label'   => 'Blog categories',
                'info'    => 'Categories articles can be filed under.',
                'type'    => 'collection',
                'group'   => 'Blog',
                'preview' => ['title', 'slug'],
                'fields'  => [
                    $this->field('title', 'text', 'Title', true),
                    $this->field('slug', 'text', 'Slug'),
                ],
            ]);
            $created = true;
        }

        if (!$content->exists(self::MODEL_AUTHORS)) {
            $content->createModel(self::MODEL_AUTHORS, [
                'label'   => 'Blog authors',
                'info'    => 'Published bylines. Not the same thing as a Cockpit account: link one here to have it used automatically for articles that account creates.',
                'type'    => 'collection',
                'group'   => 'Blog',
                'preview' => ['name'],
                'fields'  => [
                    $this->field('name', 'text', 'Name', true),
                    $this->field('bio', 'text', 'Bio'),
                    $this->field('photo', 'asset', 'Photo'),
                    $this->field('user', 'text', 'Cockpit user id', false, [
                        'info' => 'Optional. Articles created by this account use this byline when no author is set.',
                    ]),
                ],
            ]);
            $created = true;
        }

        if (!$content->exists(self::MODEL_POSTS)) {
            $content->createModel(self::MODEL_POSTS, [
                'label'   => 'Blog articles',
                'info'    => 'The articles. Unpublished articles are invisible to the public site.',
                'type'    => 'collection',
                'group'   => 'Blog',
                'preview' => ['title', 'slug'],
                'fields'  => [
                    $this->field('title', 'text', 'Title', true),
                    $this->field('slug', 'text', 'Slug', false, ['info' => 'Derived from the title when left empty. Changing it after publishing breaks existing links.']),
                    $this->link('blog', 'Blog', self::MODEL_BLOGS, 'title', true),
                    $this->field('excerpt', 'text', 'Excerpt', false, ['info' => 'Used as the meta description and in listings.']),
                    $this->field('body', 'wysiwyg', 'Body'),
                    $this->field('cover', 'asset', 'Cover image'),
                    $this->link('category', 'Category', self::MODEL_CATEGORIES, 'title'),
                    $this->link('author', 'Author', self::MODEL_AUTHORS, 'name'),
                    $this->field('publishedAt', 'date', 'Published at', false, ['info' => 'Controls ordering. Set to the save date when left empty.']),
                    // SEO fields
                    $this->field('seoTitle', 'text', 'SEO Title', false, ['info' => 'Override the <title> tag. Falls back to the article title when empty.']),
                    $this->field('seoDescription', 'text', 'SEO Description', false, ['info' => 'Override the meta description. Falls back to excerpt when empty.']),
                    $this->field('seoImage', 'asset', 'SEO Image', false, ['info' => 'Override the OG image. Falls back to cover when empty.']),
                    $this->field('seoJsonLd', 'code', 'JSON-LD', false, ['info' => 'Custom structured data for search engines (schema.org).']),
                    $this->field('seoCanonical', 'text', 'Canonical URL', false, ['info' => 'Override the canonical URL. Leave empty to use the article path.']),
                    $this->field('seoNoIndex', 'boolean', 'No Index', false, ['info' => 'If set, search engines will not index this article.']),
                ],
            ]);
            $created = true;
        }

        // Writing a model definition updates the database, but Content\Helper\Model
        // caches the registry under the 'content.models' memory key and only
        // bypasses it when debug is on. Without this rebuild the models are
        // invisible on any non-debug environment: the API answers
        // "Model <name> not found" while the definition sits correct in the
        // database. See src/knowledge/cockpit-model-registry-cache.md.
        // Models created before a field existed keep their old definition
        // forever: ensureModels() only ever creates what is missing.
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
     * Brings an existing blogPosts model up to the current field list.
     *
     * The per-article SEO overrides were added after the addon shipped. The
     * application has read them from day one - seoTitle, seoDescription and the
     * rest feed the resolved meta tags - so on a project created before they
     * existed the code runs and finds nothing, and an editor has nowhere to
     * write them. The feature looks present and is unreachable.
     *
     * Appends only. Existing fields keep their place and their settings, and
     * stored articles are never touched.
     */
    protected function migrateModels($content): bool {

        if (!$content->exists(self::MODEL_POSTS)) {
            return false;
        }

        $model  = $content->model(self::MODEL_POSTS);
        $fields = $model['fields'] ?? [];
        $names  = array_column($fields, 'name');

        $additions = [
            'seoTitle'       => $this->field('seoTitle', 'text', 'SEO Title', false, ['info' => 'Override the <title> tag. Falls back to the article title when empty.']),
            'seoDescription' => $this->field('seoDescription', 'text', 'SEO Description', false, ['info' => 'Override the meta description. Falls back to excerpt when empty.']),
            'seoImage'       => $this->field('seoImage', 'asset', 'SEO Image', false, ['info' => 'Override the OG image. Falls back to cover when empty.']),
            'seoJsonLd'      => $this->field('seoJsonLd', 'code', 'JSON-LD', false, ['info' => 'Custom structured data for search engines (schema.org).']),
            'seoCanonical'   => $this->field('seoCanonical', 'text', 'Canonical URL', false, ['info' => 'Override the canonical URL. Leave empty to use the article path.']),
            'seoNoIndex'     => $this->field('seoNoIndex', 'boolean', 'No Index', false, ['info' => 'If set, search engines will not index this article.']),
        ];

        $added = [];

        foreach ($additions as $name => $definition) {
            if (in_array($name, $names, true)) continue;
            $fields[] = $definition;
            $added[] = $name;
        }

        if (!$added) {
            return false;
        }

        try {
            $content->updateModel(self::MODEL_POSTS, ['fields' => $fields]);
            $this->log('added missing SEO fields to '.self::MODEL_POSTS.': '.implode(', ', $added));
            return true;
        } catch (\Throwable $e) {
            $this->log('blogPosts SEO field migration failed: '.$e->getMessage());
            return false;
        }
    }

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

    /**
     * Reference to an item of another collection.
     *
     * Cockpit stores these as {_model, _id} rather than the document, so a
     * consumer needs `populate` with a depth to read the target's fields.
     * See src/knowledge/cockpit-collection-reads.md.
     */
    protected function link(string $name, string $label, string $model, string $display, bool $required = false): array {
        return $this->field($name, 'contentItemLink', $label, $required, [
            'opts' => ['link' => $model, 'display' => $display],
        ]);
    }

    // ---------------------------------------------------------------- slugs

    /**
     * URL-safe slug: transliterated to ASCII, lowercased, non-alphanumerics
     * collapsed to single hyphens.
     */
    public function slugify(string $value): string {

        $value = trim($value);

        if ($value === '') {
            return '';
        }

        // iconv gives the accent folding (diseño -> diseno). It is locale
        // sensitive and can fail on some inputs, so fall back to the raw string
        // rather than returning an empty slug.
        $ascii = @iconv('UTF-8', 'ASCII//TRANSLIT', $value);

        if ($ascii !== false) {
            // //TRANSLIT can emit "a, 'e and similar; drop the decorations.
            $value = preg_replace('/[\'"^~`]/', '', $ascii);
        }

        $value = strtolower($value);
        $value = preg_replace('/[^a-z0-9]+/', '-', $value);

        return trim($value, '-');
    }

    /**
     * Normalises an article before it is stored: derives the slug from the
     * title when empty, and refuses a duplicate within the same blog.
     *
     * Uniqueness is scoped to the blog because the URL is /{blog}/{slug}, so
     * two blogs may each own the same slug. Cockpit's own `meta.unique` cannot
     * express that - isContentUnique() runs an $or across the whole collection
     * with no scoping - so the check lives here.
     */
    public function beforeSavePost(array &$item, bool $isUpdate): void {

        $slug = $this->slugify((string)($item['slug'] ?? ''));

        if ($slug === '') {
            $slug = $this->slugify((string)($item['title'] ?? ''));
        }

        if ($slug === '') {
            throw new \App\Exception\AppNotification('An article needs a title or a slug.');
        }

        $item['slug'] = $slug;

        $blogId = $this->linkId($item['blog'] ?? null);

        if ($blogId && $this->slugTaken(self::MODEL_POSTS, $slug, $item['_id'] ?? null, $blogId)) {
            throw new \App\Exception\AppNotification("Another article in this blog already uses the slug \"{$slug}\".");
        }

        if (empty($item['publishedAt'])) {
            $item['publishedAt'] = date('Y-m-d');
        }
    }

    /**
     * Normalises a blog before it is stored: slug derived from the title,
     * unique across blogs, and never one of the paths the site already serves.
     */
    public function beforeSaveBlog(array &$item, bool $isUpdate): void {

        $slug = $this->slugify((string)($item['slug'] ?? ''));

        if ($slug === '') {
            $slug = $this->slugify((string)($item['title'] ?? ''));
        }

        if ($slug === '') {
            throw new \App\Exception\AppNotification('A blog needs a title or a slug.');
        }

        if (in_array($slug, self::RESERVED_SLUGS, true)) {
            throw new \App\Exception\AppNotification("\"{$slug}\" is reserved by the site and cannot be a blog slug.");
        }

        if ($this->slugTaken(self::MODEL_BLOGS, $slug, $item['_id'] ?? null)) {
            throw new \App\Exception\AppNotification("Another blog already uses the slug \"{$slug}\".");
        }

        $item['slug'] = $slug;
    }

    /**
     * Is this slug already used, ignoring the item being saved?
     *
     * $blogId scopes the search to one blog; omitted, it searches the whole
     * collection.
     */
    protected function slugTaken(string $model, string $slug, ?string $selfId, ?string $blogId = null): bool {

        $filter = ['slug' => $slug];

        if ($blogId !== null) {
            $filter['blog._id'] = $blogId;
        }

        $existing = $this->app->module('content')->item($model, $filter);

        if (!$existing) {
            return false;
        }

        return ($existing['_id'] ?? null) !== $selfId;
    }

    /**
     * The _id out of a contentItemLink value, which is stored as {_model, _id}.
     */
    protected function linkId($value): ?string {

        if (is_array($value)) {
            // multiple: false still stores a single object, but be forgiving.
            if (isset($value['_id'])) return (string)$value['_id'];
            if (isset($value[0]['_id'])) return (string)$value[0]['_id'];
        }

        return null;
    }

    // --------------------------------------------------------------- byline

    /**
     * The byline for an article.
     *
     * The explicit author reference wins. When it is empty the article falls
     * back to the blogAuthors entry linked to the Cockpit account that created
     * it (`_cby`), so somebody writing their own blog never has to pick an
     * author, while an agency publishing for a client still can.
     *
     * Returns only display fields. The underlying Cockpit account is never
     * exposed - those are staff accounts and carry e-mail addresses.
     */
    public function byline(array $post): ?array {

        $content = $this->app->module('content');
        $author  = null;

        if ($id = $this->linkId($post['author'] ?? null)) {
            $author = $content->item(self::MODEL_AUTHORS, ['_id' => $id]);
        }

        if (!$author && !empty($post['_cby'])) {
            $author = $content->item(self::MODEL_AUTHORS, ['user' => (string)$post['_cby']]);
        }

        if (!$author) {
            return null;
        }

        return [
            'name'  => $author['name'] ?? '',
            'bio'   => $author['bio'] ?? '',
            'photo' => $author['photo'] ?? null,
        ];
    }

    // ---------------------------------------------------------------- admin

    /**
     * Blogs, newest first, for the admin screen's sidebar.
     */
    public function blogs(): array {
        return $this->app->module('content')->items(self::MODEL_BLOGS, [
            'sort' => ['title' => 1],
        ]) ?: [];
    }

    /**
     * Articles of one blog for the admin screen, with the byline resolved and
     * the public URL built when the site URL is configured.
     */
    public function posts(?string $blogId = null, int $limit = 100): array {

        $options = ['sort' => ['publishedAt' => -1], 'limit' => $limit];

        if ($blogId) {
            $options['filter'] = ['blog._id' => $blogId];
        }

        $posts = $this->app->module('content')->items(self::MODEL_POSTS, $options) ?: [];
        $blogs = [];

        foreach ($this->blogs() as $blog) {
            $blogs[$blog['_id']] = $blog;
        }

        $site = $this->siteUrl();

        foreach ($posts as &$post) {

            $blog = $blogs[$this->linkId($post['blog'] ?? null)] ?? null;

            $post['blogTitle'] = $blog['title'] ?? null;
            $post['byline']    = $this->byline($post);
            $post['url']       = ($site && $blog && !empty($post['slug']))
                ? "{$site}/{$blog['slug']}/{$post['slug']}"
                : null;
        }

        return $posts;
    }

    protected function log(string $message): void {
        error_log('[blog] '.$message);
    }
}
