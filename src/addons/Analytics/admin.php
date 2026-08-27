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

$this->on('app.permissions.collect', function(ArrayObject $permissions) {

    $permissions['Analytics'] = [
        'analytics/manage' => 'Manage analytics integrations',
    ];
});
