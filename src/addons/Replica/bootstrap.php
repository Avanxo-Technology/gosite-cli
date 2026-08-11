<?php
/**
 * Replica - content replication between Cockpit v2 instances.
 *
 * Independent project, MIT licensed. Not affiliated with or derived from any
 * commercial Cockpit addon.
 *
 * Storage (dataStorage, not content collections - this is operator config, not
 * editorial content):
 *   replica/targets   remote instances and their scope selection
 *   replica/log       one document per operation
 *   replica/idmap     source id <-> remote id pairs, for targets that cannot
 *                     keep our _id (see Helper\Client, core transport)
 *
 * Admin screen:  GET /replica
 * Admin API:     /replica/api/*        (session auth + replica/manage + CSRF)
 * Peer API:      /api/replica/*        (api-key auth + replica/manage)
 *
 * NOTE: the addon folder MUST be named "Replica" with a capital R - Lime's
 * autoloader maps the namespace straight onto the directory name, so a
 * lowercase folder works on macOS and fatals on Linux.
 */

if (!defined('REPLICA_TARGETS')) define('REPLICA_TARGETS', 'replica/targets');
if (!defined('REPLICA_LOG'))     define('REPLICA_LOG', 'replica/log');
if (!defined('REPLICA_IDMAP'))   define('REPLICA_IDMAP', 'replica/idmap');

// Helpers: assign to the array - $app->helper('x', 'Class') does not register.
$this->helpers['replica']        = 'Replica\\Helper\\Replica';
$this->helpers['replica.client'] = 'Replica\\Helper\\Client';

/**
 * Admin API controller.
 *
 * Bound before the '/replica' screen: Lime resolves routes in registration
 * order, so '/replica/api' must win over '/replica'.
 */
$this->bindClass('Replica\\Controller\\Api', '/replica/api');

// Admin UI
$this->on('app.admin.init', function() {
    include(__DIR__.'/admin.php');
});

// Peer REST endpoints under /api/replica/...
$this->on('app.api.request', function() {
    include(__DIR__.'/api.php');
});

// CLI commands
$this->on('app.cli.init', function($cli) {
    $app = $this;
    include(__DIR__.'/cli.php');
});
