<?php

// Admin screen: GET /analytics
$this->bindClass('Analytics\\Controller\\Admin', '/analytics');

$this->on('app.layout.init', function() {

    if (!$this->helper('acl')->isAllowed('analytics/manage')) {
        return;
    }

    $this->helper('analytics')->ensureModels();

    $this->helper('menus')->addLink('modules', [
        'label'  => 'Analytics',
        'icon'   => 'analytics:assets/icons/analytics.svg',
        'route'  => '/analytics',
        'active' => false
    ]);
});

/*
 * Pre-fill the config field with the right keys when a provider is chosen.
 *
 * The templates travel as data on window, not baked into the script, so the
 * shape the editor is offered comes from the same RULES the screen validates
 * against and the two cannot drift apart.
 */
$this->on('app.layout.assets', function(array &$assets, $context) {

    if ($context !== 'app:footer' || !$this->helper('acl')->isAllowed('analytics/manage')) {
        return;
    }

    $assets[] = ['src' => 'analytics:assets/js/config-template.js'];
});

$this->on('app.layout.head', function() {
    if (!$this->helper('acl')->isAllowed('analytics/manage')) {
        return;
    }
    echo '<script>window.ANALYTICS_CONFIG_TEMPLATES = '
        .json_encode($this->helper('analytics')->configTemplates(), JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT)
        .';</script>';
});

$this->on('app.permissions.collect', function(ArrayObject $permissions) {

    $permissions['Analytics'] = [
        'analytics/manage' => 'Manage analytics integrations',
    ];
});
