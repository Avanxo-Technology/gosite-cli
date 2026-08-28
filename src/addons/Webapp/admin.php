<?php

// Admin screen: GET /webapp
$this->bindClass('Webapp\\Controller\\Admin', '/webapp');

// Sidebar entry under "Modules"
$this->on('app.layout.init', function() {

    if (!$this->helper('acl')->isAllowed('webapp/manage')) {
        return;
    }

    // Creates models on first admin load.
    $this->helper('webapp')->ensureModels();

    $this->helper('menus')->addLink('modules', [
        'label'  => 'Webapp',
        'icon'   => 'webapp:assets/icons/webapp.svg',
        'route'  => '/webapp',
        'active' => false
    ]);
});

// Expose the permission in Settings > Roles
$this->on('app.permissions.collect', function(ArrayObject $permissions) {

    $permissions['Webapp'] = [
        'webapp/manage' => 'Manage webapp settings and SEO',
    ];
});
