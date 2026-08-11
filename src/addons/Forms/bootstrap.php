<?php
/**
 * Forms - Inbox-style form submission manager for Cockpit v2 (core-2.14.0).
 *
 * Submissions are stored in ordinary Content collections, created automatically
 * on first use:
 *
 *   formSubmissions  form, data (object), origin, ip, userAgent, read
 *   formSettings     form, label, notify, subject, webhook, webhookSecret,
 *                    throttle, dailyLimit
 *
 * Public receiver (no auth):
 *   POST /forms/api/submit
 *
 * Admin API (acl forms/manage, CSRF on mutations):
 *   GET  /forms/api/list?form=...&page=...
 *   GET  /forms/api/forms
 *   GET  /forms/api/export?form=...
 *   POST /forms/api/remove/{id}
 *   POST /forms/api/read/{id}
 *
 * Admin screen:
 *   GET  /forms
 *
 * NOTE: the addon directory MUST be named "Forms" with a capital F. Lime's
 * autoloader maps the namespace straight onto the directory name, so a
 * lowercase folder only works on case-insensitive filesystems (macOS) and
 * fatals on Linux. The "forms:" path alias is registered automatically by
 * Lime\App::registerModule(), which lowercases the module name.
 */

// Helper holding all business logic (shared by controllers + REST API).
$this->helpers['forms'] = 'Forms\\Helper\\Forms';

/**
 * API controller, bound here rather than in admin.php so the public
 * /forms/api/submit route exists on every request cycle.
 *
 * Registration order matters: '/forms/api' must be bound before '/forms'
 * (admin.php), otherwise bindClass('/forms') swallows these routes.
 */
$this->bindClass('Forms\\Controller\\Api', '/forms/api');

// Admin UI (menu entry + screen)
$this->on('app.admin.init', function() {
    include(__DIR__.'/admin.php');
});

// Token-authenticated REST surface under /api/forms/...
$this->on('app.api.request', function() {
    include(__DIR__.'/api.php');
});
