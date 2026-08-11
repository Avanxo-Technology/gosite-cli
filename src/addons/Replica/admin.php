<?php

// Admin screen: GET /replica
$this->bindClass('Replica\\Controller\\Admin', '/replica');

// Sidebar entry under "Modules"
$this->on('app.layout.init', function() {

    if (!$this->helper('acl')->isAllowed('replica/manage')) {
        return;
    }

    $this->helper('menus')->addLink('modules', [
        'label'  => 'Replica',
        'icon'   => 'replica:assets/icons/replica.svg',
        'route'  => '/replica',
        'active' => false
    ]);
});

// Expose the permission in Settings > Roles
$this->on('app.permissions.collect', function(ArrayObject $permissions) {

    $permissions['Replica'] = [
        'replica/manage' => 'Manage replication targets and run push/pull',
    ];
});
