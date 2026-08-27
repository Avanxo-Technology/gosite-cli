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
$env   = getenv('APP_ENV') ?: '(unset)';
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
                            // "Live here" means: switched on AND covering the
                            // environment this CMS is running in. Both have to
                            // be true, and one without the other is the usual
                            // reason somebody reports missing data.
                            $live = $enabled && ($applies === 'all' || $applies === $env);
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
                                <?php if (!$live): ?>
                                    <div class="kiss-size-xsmall kiss-color-muted">not live in <?= htmlspecialchars($env) ?></div>
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

    <div class="kiss-size-xsmall kiss-color-muted kiss-margin-small-top">
        This CMS reports <code>APP_ENV=<?= htmlspecialchars($env) ?></code>. The website decides
        the same way, from its own environment.
    </div>
</kiss-container>
