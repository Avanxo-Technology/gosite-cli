<?php

// Admin screen: GET /forms
$this->bindClass('Forms\\Controller\\Admin', '/forms');

// Sidebar entry under "Modules"
$this->on('app.layout.init', function() {

    if (!$this->helper('acl')->isAllowed('forms/manage')) {
        return;
    }

    // Installs the formSubmissions / formSettings models on first admin load,
    // so the collections exist before anyone opens the screen.
    $this->helper('forms')->ensureModels();

    $this->helper('menus')->addLink('modules', [
        'label'  => 'Forms',
        'icon'   => 'forms:assets/icons/forms.svg',
        'route'  => '/forms',
        'active' => false
    ]);
});

// Expose the permission in Settings > Roles
$this->on('app.permissions.collect', function(ArrayObject $permissions) {

    $permissions['Forms'] = [
        'forms/manage' => 'Manage form submissions',
    ];
});
