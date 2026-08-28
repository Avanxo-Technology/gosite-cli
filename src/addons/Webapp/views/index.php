<?php
/**
 * Webapp admin screen.
 *
 * Read-only on purpose: editing happens in the Content editor, which already
 * knows how to render an asset picker, a WYSIWYG and a code field. What this
 * screen adds is the thing Content cannot show - site-wide SEO defaults and
 * every per-page override at a glance.
 *
 * - SEO Configuration: the webapp singleton, shown read-only. "Edit in
 *   Content" opens /content/singleton/item/webapp, where the favicon and the
 *   default image are real asset fields.
 * - SEO Pages: the seoPages collection, shown read-only. Rows link to their
 *   editor and "Add page" opens the new-entry editor.
 *
 * Rendered server-side, like the Analytics screen, because the dataset is a
 * handful of rows and there is nothing to page through.
 */

$app        = $this;
$model      = Webapp\Helper\Webapp::MODEL_WEBAPP;
$pagesModel = Webapp\Helper\Webapp::MODEL_SEO_PAGES;

// Resolve an asset value ({path, url} or bare path) to a public URL.
//
// An asset's `path` is relative to the uploads root ("2026/08/28/foo.png") and
// the store may be S3/MinIO, so only the file storage knows the public URL -
// pathToUrl() cannot build it and returned nothing, which is why real assets
// rendered as "Not set".
$assetUrl = function ($value) use ($app) {

    if (is_array($value)) {
        if (!empty($value['url'])) return $value['url'];
        $path = trim((string)($value['path'] ?? ''), '/');
    } else {
        $path = trim((string)$value, '/');
    }

    if (!$path) return '';

    // fileStorage lives on the app instance; $this (the controller) proxies to
    // it, unlike $app->app which is null in the view scope.
    try {
        return (string)$this->fileStorage->getURL("uploads://{$path}") ?: '';
    } catch (\Throwable $e) {
        return '';
    }
};

// Whether an asset field holds anything at all. Kept separate from $assetUrl so
// a stored asset whose URL cannot be resolved still reads as set, rather than
// silently reporting "Not set".
$assetIsSet = function ($value) {
    if (is_array($value)) {
        return (bool)($value['_id'] ?? ($value['path'] ?? ($value['url'] ?? '')));
    }
    return is_string($value) && trim($value) !== '';
};

// Text fields are shown as text. strip_tags covers values saved while a field
// was still a wysiwyg - llmText was one until it became a plain textarea.
$plainText = function ($value) {
    if (is_array($value) || is_object($value)) {
        return trim((string)json_encode($value));
    }
    return trim(html_entity_decode(strip_tags((string)$value), ENT_QUOTES | ENT_HTML5, 'UTF-8'));
};

// Generators for the fields nobody wants to write by hand. Shown only next to
// an empty field: once there is a value the hint is noise.
$fieldHelp = [
    'llmText'   => ['label' => 'Generate llms.txt', 'url' => 'https://seomator.com/free-llms-txt-generator'],
    'jsonLd'    => ['label' => 'Generate JSON-LD',  'url' => 'https://jsonld.com/json-ld-generator/'],
    'robotsTxt' => ['label' => 'Generate robots.txt', 'url' => 'https://technicalseo.com/tools/robots-txt/'],
];

// The "Not set" cell, plus a link to a generator when one exists for the field.
$notSet = function ($name) use ($fieldHelp) {
    $out = '<span class="kiss-color-muted">Not set</span>';

    if (isset($fieldHelp[$name])) {
        $help = $fieldHelp[$name];
        $out .= '<a class="kiss-margin-small-left kiss-size-small" target="_blank" rel="noopener noreferrer"'
            .' href="'.htmlspecialchars($help['url']).'">'
            .htmlspecialchars($help['label']).' <icon>open_in_new</icon></a>';
    }

    return $out;
};
?>

<kiss-container class="kiss-margin-small">

    <ul class="kiss-breadcrumbs">
        <li><a href="<?= $this->route('/webapp') ?>">Webapp</a></li>
    </ul>

    <div class="kiss-flex kiss-flex-middle kiss-margin-bottom" gap="small">
        <div class="kiss-margin-small-right">
            <kiss-svg src="<?= $this->base('webapp:assets/icons/webapp.svg') ?>" width="40" height="40"><canvas width="40" height="40"></canvas></kiss-svg>
        </div>
        <div class="kiss-flex-1">
            <h1 class="kiss-size-4 kiss-margin-remove">Webapp</h1>
            <div class="kiss-size-small kiss-color-muted">Site configuration and SEO management</div>
        </div>
        <a class="kiss-button kiss-button-primary kiss-flex kiss-flex-middle" gap="xsmall"
           href="<?= $this->route('/content/singleton/item/'.$model) ?>">
            <icon>edit</icon> Edit in Content
        </a>
    </div>

    <kiss-card class="kiss-padding-small kiss-margin-bottom" theme="contrast">
        <div class="kiss-size-small kiss-color-muted">
            <icon class="kiss-margin-xsmall-right">info</icon>
            These fields come from the <b>webapp</b> singleton and are served as the site's default
            SEO. The favicon and the default image are <b>asset fields</b> — pick a file in the
            Assets media library.
            <br>
            Edit them with <b>Edit in Content</b>, which opens the same editor you use for any other
            content. Per-page overrides live in <b>SEO Pages</b> below.
        </div>
    </kiss-card>

    <!-- SEO Configuration (read-only summary) -->
    <kiss-card theme="contrast shadowed" class="kiss-padding-small">

        <div class="kiss-flex kiss-flex-middle kiss-margin-small-bottom" gap="small">
            <div class="webapp-section-title kiss-flex-1 kiss-text-bold">SEO Configuration</div>
            <span class="kiss-flex-1"></span>
            <a class="kiss-button kiss-button-small" href="<?= $this->route('/content/singleton/item/'.$model) ?>">
                <icon>edit</icon> Edit in Content
            </a>
        </div>

        <?php if (!$webappConfig): ?>
            <div class="kiss-padding kiss-align-center kiss-color-muted">
                No site-wide SEO configured yet.&nbsp;
                <a href="<?= $this->route('/content/singleton/item/'.$model) ?>">Open the webapp singleton</a> to set the defaults.
            </div>
        <?php else: ?>

            <table class="kiss-table kiss-size-small">
                <tbody>
                    <?php foreach ($webappFields as $field): ?>
                        <?php
                            $name  = $field['name'] ?? '';
                            $label = $field['label'] ?: $name;
                            $type  = $field['type'] ?? 'text';
                            $value = $webappConfig[$name] ?? null;
                        ?>
                        <tr>
                            <th width="200" class="kiss-text-bold" title="<?= htmlspecialchars((string)($field['info'] ?? '')) ?>">
                                <?= htmlspecialchars($label) ?>
                            </th>
                            <td>
                                <?php if ($type === 'asset'): ?>

                                    <?php $url = $assetUrl($value); ?>
                                    <?php if ($url): ?>
                                        <a href="<?= htmlspecialchars($url) ?>" target="_blank" rel="noopener">
                                            <img src="<?= htmlspecialchars($url) ?>" alt="<?= htmlspecialchars($label) ?>"
                                                 style="height:32px;object-fit:contain;vertical-align:middle;border-radius:4px;">&nbsp;<icon>open_in_new</icon>
                                        </a>
                                    <?php elseif ($assetIsSet($value)): ?>
                                        <span class="kiss-color-success">Set</span>
                                        <span class="kiss-color-muted kiss-margin-small-left">(preview unavailable)</span>
                                    <?php else: ?>
                                        <?= $notSet($name) ?>
                                    <?php endif; ?>

                                <?php elseif ($type === 'code'): ?>

                                    <?php $text = trim((string)$value); ?>
                                    <?php if ($text !== ''): ?>
                                        <pre class="kiss-text-monospace kiss-size-small" style="margin:0;max-height:120px;overflow:auto;background:transparent;border:0;padding:0;color:inherit;white-space:pre-wrap;"><?= htmlspecialchars($text) ?></pre>
                                    <?php else: ?>
                                        <?= $notSet($name) ?>
                                    <?php endif; ?>

                                <?php elseif ($type === 'boolean'): ?>

                                    <?= $value ? 'Yes' : '<span class="kiss-color-muted">No</span>' ?>

                                <?php else: ?>

                                    <?php $text = $plainText($value); ?>
                                    <?= $text !== '' ? htmlspecialchars(mb_strimwidth($text, 0, 220, '…')) : $notSet($name) ?>

                                <?php endif; ?>
                            </td>
                        </tr>
                    <?php endforeach; ?>
                </tbody>
            </table>

        <?php endif; ?>

    </kiss-card>

    <!-- SEO Pages (read-only list) -->
    <kiss-card theme="contrast shadowed" class="kiss-padding-small kiss-margin-top">

        <div class="kiss-flex kiss-flex-middle kiss-margin-small-bottom" gap="small">
            <div class="webapp-section-title kiss-flex-1 kiss-text-bold">SEO Pages</div>
            <span class="kiss-flex-1"></span>
            <a class="kiss-button kiss-button-small" href="<?= $this->route('/content/collection/item/'.$pagesModel) ?>">
                <icon>add</icon> Add page
            </a>
        </div>

        <?php if (!count($seoPages)): ?>
            <div class="kiss-padding kiss-align-center kiss-color-muted">
                No SEO pages configured. Per-page overrides let a specific route (e.g. <code>/about</code>)
                define its own title, description, image and more.&nbsp;
                <a href="<?= $this->route('/content/collection/item/'.$pagesModel) ?>">Add your first page</a>.
            </div>
        <?php else: ?>
            <table class="kiss-table kiss-size-small" table-scroll>
                <thead>
                    <tr>
                        <th width="40"></th>
                        <th class="kiss-text-bold" width="260">Path</th>
                        <th class="kiss-text-bold">Title</th>
                        <th class="kiss-text-bold" width="110">Robots</th>
                    </tr>
                </thead>
                <tbody>
                    <?php foreach ($seoPages as $page): ?>
                        <?php $editUrl = $this->route('/content/collection/item/'.$pagesModel.'/'.$page['_id']); ?>
                        <tr>
                            <td>
                                <a class="kiss-badge kiss-link-muted"
                                   href="<?= htmlspecialchars($editUrl) ?>"
                                   title="<?= htmlspecialchars($page['_id']) ?>">
                                    <icon>edit</icon>...<?= htmlspecialchars(substr((string)$page['_id'], -5)) ?>
                                </a>
                            </td>
                            <td>
                                <a href="<?= htmlspecialchars($editUrl) ?>" class="kiss-text-monospace">
                                    <?= htmlspecialchars($page['path'] ?? '') ?>
                                </a>
                            </td>
                            <td>
                                <?= htmlspecialchars($page['title'] ?? '(no title)') ?>
                                <?php if (!empty($page['canonical'])): ?>
                                    <div class="kiss-size-xsmall kiss-color-muted">canonical: <?= htmlspecialchars($page['canonical']) ?></div>
                                <?php endif; ?>
                            </td>
                            <td>
                                <?php if (!empty($page['noIndex'])): ?>
                                    <span class="kiss-badge kiss-badge-outline kiss-color-danger">noindex</span>
                                <?php else: ?>
                                    <span class="kiss-badge kiss-badge-outline kiss-color-success">index</span>
                                <?php endif; ?>
                            </td>
                        </tr>
                    <?php endforeach; ?>
                </tbody>
            </table>
        <?php endif; ?>

    </kiss-card>

    <kiss-card class="kiss-padding-small kiss-margin-top" theme="contrast">
        <div class="kiss-size-small kiss-color-muted">
            <icon class="kiss-margin-xsmall-right">help_outline</icon>
            <b>How per-page SEO is resolved</b>
            <br>
            When a page is rendered, overrides are applied in this order — the first that is set wins:
            <code>page overrides</code> (handler) → <code>SEO Pages</code> (this collection, matched by path)
            → <code>webapp</code> defaults (above). The favicon, robots.txt and LLM text are site-wide and
            only take values from the <b>webapp</b> singleton.
        </div>
    </kiss-card>

</kiss-container>

<style>
    .webapp-section-title {
        font-size: 0.8rem;
        letter-spacing: 0.02em;
        color: #666;
    }
    .kiss-pre {
        margin: 0;
        padding: 0.5rem 0.75rem;
        background: #f6f6f6;
        border-radius: 4px;
        font-size: 0.8rem;
    }
</style>
