<?php

// Admin screen: GET /blog
$this->bindClass('Blog\\Controller\\Admin', '/blog');

// Sidebar entry under "Modules"
$this->on('app.layout.init', function() {

    if (!$this->helper('acl')->isAllowed('blog/manage')) {
        return;
    }

    // Installs the four models on first admin load, so the collections exist
    // before anyone opens the screen.
    $this->helper('blog')->ensureModels();

    $this->helper('menus')->addLink('modules', [
        'label'  => 'Blog',
        'icon'   => 'blog:assets/icons/blog.svg',
        'route'  => '/blog',
        'active' => false
    ]);
});

// Expose the permission in Settings > Roles
$this->on('app.permissions.collect', function(ArrayObject $permissions) {

    $permissions['Blog'] = [
        'blog/manage' => 'Manage blog articles',
    ];
});
