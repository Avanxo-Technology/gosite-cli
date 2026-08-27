<?php
/**
 * Analytics admin screen.
 *
 * Read-only on purpose: editing happens in the Content editor, which already
 * knows how to render a select, an object and a boolean. What this screen adds
 * is the thing Content cannot show - every integration at a glance, with the
 * state and the environment that decide whether it is actually live.
 *
 * Rendered server-side rather than through an API, because the whole dataset is
 * a handful of rows and there is nothing to page through.
 */
$model = Analytics\Helper\Analytics::MODEL;
?>

<kiss-container class="kiss-margin-small">

    <ul class="kiss-breadcrumbs">
        <li><a href="<?= $this->route('/analytics') ?>">Analytics</a></li>
    </ul>

    <div class="kiss-flex kiss-flex-middle kiss-margin-bottom" gap="small">
        <div class="kiss-margin-small-right">
            <kiss-svg src="<?= $this->base('analytics:assets/icons/analytics.svg') ?>" width="40" height="40"><canvas width="40" height="40"></canvas></kiss-svg>
        </div>
        <div class="kiss-flex-1">
            <h1 class="kiss-size-4 kiss-margin-remove">Analytics</h1>
            <div class="kiss-size-small kiss-color-muted">Third-party tracking loaded by your website</div>
        </div>
        <a class="kiss-button kiss-button-primary kiss-flex kiss-flex-middle" gap="xsmall"
           href="<?= $this->route('/content/collection/item/'.$model) ?>">
            <icon>add</icon> New integration
        </a>
    </div>

    <kiss-card class="kiss-padding-small kiss-margin-bottom" theme="contrast">
        <div class="kiss-size-small kiss-color-muted">
            <icon class="kiss-margin-xsmall-right">info</icon>
            These values are <b>public</b> — they are served in the HTML of every page, where
            anyone can read them. That is what makes them safe to keep here. Never put a real
            credential in this collection.
        </div>
    </kiss-card>

    <kiss-card theme="contrast shadowed" class="kiss-padding-small">

        <?php if (!count($integrations)): ?>
            <div class="kiss-padding kiss-align-center kiss-color-muted">
                No integrations yet.
            </div>
        <?php else: ?>
            <table class="kiss-table" table-scroll>
                <thead>
                    <tr>
                        <th fixed="left" width="70">ID</th>
                        <th class="kiss-align-center" width="20">On</th>
                        <th width="180">Provider</th>
                        <th>Configuration</th>
                        <th width="130">Applies to</th>
                    </tr>
                </thead>
                <tbody>
                    <?php foreach ($integrations as $item): ?>
                        <?php
                            $enabled = !empty($item['enabled']);
                            $applies = $item['environments'] ?? 'all';
                        ?>
                        <tr>
                            <td fixed="left">
                                <a class="kiss-badge kiss-link-muted"
                                   href="<?= $this->route('/content/collection/item/'.$model.'/'.$item['_id']) ?>"
                                   title="<?= htmlspecialchars($item['_id']) ?>">
                                    <icon>edit</icon>...<?= htmlspecialchars(substr($item['_id'], -5)) ?>
                                </a>
                            </td>
                            <td class="kiss-align-center">
                                <icon class="<?= $enabled ? 'kiss-color-success' : 'kiss-color-muted' ?>">trip_origin</icon>
                            </td>
                            <td>
                                <?= htmlspecialchars($this->helper('analytics')->providerLabel($item['provider'] ?? '')) ?>
                                <?php if (!$enabled): ?>
                                    <div class="kiss-size-xsmall kiss-color-muted">disabled everywhere</div>
                                <?php endif; ?>
                            </td>
                            <td class="kiss-size-small kiss-text-monospace">
                                <?php $config = is_array($item['config'] ?? null) ? $item['config'] : []; ?>
                                <?php if (!count($config)): ?>
                                    <span class="kiss-badge kiss-badge-outline kiss-color-danger">empty</span>
                                <?php else: ?>
                                    <?php foreach ($config as $key => $value): ?>
                                        <div><?= htmlspecialchars($key) ?>: <?= htmlspecialchars((string)$value) ?></div>
                                    <?php endforeach; ?>
                                <?php endif; ?>
                            </td>
                            <td class="kiss-size-small">
                                <span class="kiss-badge kiss-badge-outline"><?= htmlspecialchars($applies) ?></span>
                            </td>
                        </tr>
                    <?php endforeach; ?>
                </tbody>
            </table>
        <?php endif; ?>

    </kiss-card>

    <?php
        /*
         * The CMS deliberately does not say whether an entry is live.
         *
         * "Applies to" is matched against the WEBSITE's APP_ENV, not this
         * container's - they are separate services and the CMS is not given
         * one. An earlier version of this screen read getenv('APP_ENV') here
         * and reported "(unset)", which was both wrong and confidently stated.
         */
    ?>
    <kiss-card class="kiss-padding-small kiss-margin-top" theme="contrast">
        <div class="kiss-size-small kiss-color-muted">
            <icon class="kiss-margin-xsmall-right">info</icon>
            <b>Applies to</b> is matched against the <b>website's</b> <code>APP_ENV</code>, not this CMS's —
            they run as separate services, and only the website reads it.
            <code>development</code> matches <code>development</code>, <code>dev</code> or <code>local</code>;
            <code>production</code> matches anything else, including unset;
            <code>all</code> always matches. An integration loads only when it is enabled
            <em>and</em> its environment matches.
        </div>
    </kiss-card>

    <?php
        /*
         * What each provider expects in `config`, and where its full option
         * list lives. Deliberately a link rather than a copy: the options
         * belong to each plugin and would go stale here the first time
         * upstream changed one.
         */
    ?>
    <kiss-card theme="contrast shadowed" class="kiss-padding-small kiss-margin-top">
        <div class="kiss-flex kiss-flex-middle kiss-margin-small-bottom" gap="xsmall">
            <icon>help_outline</icon>
            <b>What each provider needs</b>
            <span class="kiss-flex-1"></span>
            <a href="<?= htmlspecialchars(Analytics\Helper\Analytics::DOCS_INDEX) ?>"
               target="_blank" rel="noopener" class="kiss-size-small">
                All plugins <icon>open_in_new</icon>
            </a>
        </div>

        <table class="kiss-table kiss-size-small">
            <thead>
                <tr>
                    <th width="200">Provider</th>
                    <th>Required in <code>config</code></th>
                    <th width="130">Options</th>
                </tr>
            </thead>
            <tbody>
                <?php foreach ($reference as $row): ?>
                    <tr>
                        <td>
                            <?= htmlspecialchars($row['label']) ?>
                            <?php if ($row['custom']): ?>
                                <span class="kiss-badge kiss-badge-outline">our plugin</span>
                            <?php endif; ?>
                            <div class="kiss-size-xsmall kiss-color-muted kiss-text-monospace"><?= htmlspecialchars($row['provider']) ?></div>
                        </td>
                        <td class="kiss-text-monospace">
                            <?php if (!count($row['keys'])): ?>
                                <span class="kiss-color-muted">see the plugin's options</span>
                            <?php else: ?>
                                <?= htmlspecialchars(implode(', ', $row['keys'])) ?>
                            <?php endif; ?>
                        </td>
                        <td>
                            <a href="<?= htmlspecialchars($row['docs']) ?>" target="_blank" rel="noopener">
                                docs <icon>open_in_new</icon>
                            </a>
                        </td>
                    </tr>
                <?php endforeach; ?>
            </tbody>
        </table>

        <div class="kiss-size-xsmall kiss-color-muted kiss-margin-small-top">
            Keys are stored under the provider's own names and passed to its plugin untouched,
            so whatever its documentation calls an option is what goes here.
        </div>
    </kiss-card>
</kiss-container>
