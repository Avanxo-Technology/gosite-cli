<?php
/**
 * Analytics - third-party tracking integrations for gosite sites.
 *
 * One collection, created automatically on first admin load:
 *
 *   analyticsIntegrations   provider, config, enabled, environments
 *
 * The application reads it through Cockpit's core REST API and renders the
 * matching browser plugin. This addon serves nothing to visitors.
 *
 * These keys are PUBLIC - a GTM container id and a PostHog project key are in
 * the HTML of every page - which is what makes it safe for a client to edit
 * them here. Do not put anything that is actually a credential in this model.
 *
 * NOTE: the addon directory MUST be named "Analytics" with a capital A. Lime's
 * autoloader maps the namespace straight onto the directory name, so a
 * lowercase folder only works on case-insensitive filesystems (macOS) and
 * fatals on Linux.
 */

$this->helpers['analytics'] = 'Analytics\\Helper\\Analytics';

// Validation runs here rather than in admin.php so it also covers writes that
// arrive through the REST API, not only edits made in the admin UI.
$this->on('content.item.save.before.analyticsIntegrations', function(&$item, $isUpdate) {
    $this->helper('analytics')->beforeSave($item, $isUpdate);
});

// Admin UI (menu entry + screen)
$this->on('app.admin.init', function() {
    include(__DIR__.'/admin.php');
});
