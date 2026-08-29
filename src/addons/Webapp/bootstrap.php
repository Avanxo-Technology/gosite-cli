<?php
/**
 * Webapp - consolidated addon for site configuration and SEO management.
 *
 * Absorbs six infrastructure addons:
 *   - AssetPathFix: strips leading slash from asset paths
 *   - AssetsUpload: REST endpoint for uploading assets
 *   - StarterContent: creates home singleton on first boot
 *   - CachePurge: purges Go app cache on content changes
 *   - CloudStorage: S3 adapter configuration
 *   - ModelManager: REST endpoints for content model CRUD
 *
 * Adds:
 *   - webapp singleton: site-wide SEO configuration
 *   - seoPages collection: per-page SEO overrides
 *   - Admin screen: SEO config + SEO pages management
 *
 * ACL: webapp/manage for all admin access.
 */

// ---------------------------------------------------------------------------
// 1. Register helpers
// ---------------------------------------------------------------------------

$this->helpers['webapp'] = 'Webapp\\Helper\\Webapp';

// CachePurge helper (absorbed) - exposed for Replica to call directly
$this->helpers['cachepurge'] = function($model = null, $item = null) {
    $this->helper('webapp')->purge($model, $item);
};

// ---------------------------------------------------------------------------
// 2. Absorbed addon: AssetPathFix
// ---------------------------------------------------------------------------
// Strips leading slash from asset paths to prevent double-slash in S3 URLs.

$this->on('assets.asset.upload', function (&$asset, &$_meta, &$opts, &$file, &$path) {
    if (is_string($path) && str_starts_with($path, '/')) {
        $path = ltrim($path, '/');
    }
    if (is_array($asset) && isset($asset['path']) && str_starts_with($asset['path'], '/')) {
        $asset['path'] = ltrim($asset['path'], '/');
    }
});

// ---------------------------------------------------------------------------
// 3. Absorbed addon: AssetsUpload
// ---------------------------------------------------------------------------
// REST endpoint for uploading assets (used by the Go application).

$this->on('restApi.config', function($restApi) {
    $restApi->addEndPoint('/assets/upload', [
        'POST' => function($params, $app) {
            $meta = ['folder' => $this->param('folder', '')];
            return $this->module('assets')->upload('files', $meta);
        }
    ]);
});

// ---------------------------------------------------------------------------
// 4. Absorbed addon: StarterContent
// ---------------------------------------------------------------------------
// Provisions the content models on first boot: the webapp singleton, the
// seoPages collection and the home singleton (all idempotently). ensureModels()
// tolerates the Content module not being ready yet and logs instead of fataling.
// Guarded by a memory flag so it only runs once per install.

$this->on('bootstrap', function() {

    try {
        if ($this->memory->get('gosite.starter.ready')) {
            return;
        }
    } catch (\Throwable $e) {
        // Fall through to the provisioning check.
    }

    try {
        $this->helper('webapp')->ensureModels();
    } catch (\Throwable $e) {
        error_log('[webapp/startercontent] '.$e->getMessage());
    }

    $this->memory->set('gosite.starter.ready', 1);
});

// ---------------------------------------------------------------------------
// 5. Absorbed addon: CachePurge
// ---------------------------------------------------------------------------
// Purges the Go app cache when Cockpit content changes.

// Saving content deliberately does NOT purge the application.
//
// It used to. The coupling turned every editorial save into a call out to the
// app, and every CMS cache flush into a site-wide purge - which is how a
// Cockpit problem became an outage on the public site. Cockpit's own flush
// empties the whole Redis database it shares with the session and API-key
// registries, so the CMS could refuse the very purge it had just asked for.
//
// The application's TTL is short and its cache carries a stale fallback, so
// content appears on its own. When it has to be immediate, the Webapp screen
// has a button that purges on request - a person deciding, not a side effect.

// Settings -> Clear cache. Cockpit empties #cache:, #tmp: and app memory, which
// includes the model registry, and the application keeps serving pages rendered
// from content that is now gone.
//
// Warm first, purge second - the reverse of how it reads. The purge makes the
// application re-render immediately, and a re-render that arrives while the
// model registry is still empty gets 404 for every model and answers with an
// error page. Warming first costs one query and removes that window entirely.
$this->on('app.system.cache.flush', function() {

    // Warm only. Cockpit's flush empties the entire Redis database - the model
    // registry, the API keys, the sessions - so the CMS comes back up needing
    // repair, and this is where that repair happens.
    //
    // It deliberately does not purge the application any more: telling the app
    // to re-render at the exact moment the CMS cannot authenticate it is how a
    // routine "Clear cache" became 502s for visitors.
    $warmed = $this->helper('webapp')->warmCockpit();

    error_log('[webapp] cache flush: warmed '.json_encode($warmed));
});

// ---------------------------------------------------------------------------
// 6. Absorbed addon: CloudStorage
// ---------------------------------------------------------------------------
// S3 adapter configuration for Cockpit core uploads.

$this->on('app.filestorage.init', function (&$storages) {

    $config = $this->cloudStorage ?? [];

    foreach ($config as $name => $opts) {

        if (isset($opts['type']) && $opts['type'] !== 's3') {
            continue;
        }

        if (empty($opts['bucket']) || empty($opts['key']) || empty($opts['secret'])) {
            continue;
        }

        $client = new Aws\S3\S3Client([
            'version' => 'latest',
            'region' => $opts['region'] ?? 'auto',
            'credentials' => [
                'key'    => $opts['key'],
                'secret' => $opts['secret'],
            ],
            'endpoint' => $opts['url'] ?? null,
            'use_path_style_endpoint' => !empty($opts['url']),
            'http' => [
                'verify' => filter_var(getenv('S3_VERIFY') ?: 'true', FILTER_VALIDATE_BOOLEAN),
            ],
        ]);

        $s3 = [
            'adapter'    => 'League\Flysystem\AwsS3V3\AwsS3V3Adapter',
            'args'       => [
                $client,
                $opts['bucket'],
                $opts['prefix'] ?? '',
            ],
            'visibility' => array_key_exists('visibility', $opts) ? $opts['visibility'] : 'public',
        ];

        if (!empty($opts['public_url'])) {
            $s3['url'] = rtrim($opts['public_url'], '/');
        }

        $existing = $storages[$name] ?? [];
        $storages[$name] = array_merge($existing, $s3);
    }
});

// ---------------------------------------------------------------------------
// 7. Absorbed addon: ModelManager
// ---------------------------------------------------------------------------
// REST endpoints for content model CRUD.

$this->on('restApi.config', function($restApi) {

    $restApi->addEndPoint('/models', [
        'GET' => function($params, $app) {
            $models = $app->module('content')->models();

            if (!$app->helper('acl')->isSuperAdmin()) {
                $acl = $app->helper('acl');
                $models = array_filter($models, function($m) use($acl) {
                    return $acl->isAllowed("content/{$m['name']}/read");
                });
            }

            return array_values($models);
        }
    ]);

    $restApi->addEndPoint('/models/save', [
        'POST' => function($params, $app) {

            $model = $app->param('model');

            if (!$model || !isset($model['name'], $model['type']) || !trim($model['name']) || !trim($model['type'])) {
                $app->response->status = 412;
                return ['error' => 'Model data is missing or invalid'];
            }

            if (!in_array($model['type'], ['collection', 'singleton', 'tree'])) {
                $app->response->status = 412;
                return ['error' => 'Invalid model type'];
            }

            if (!$app->helper('acl')->isAllowed("content/:models/manage") && !$app->helper('acl')->isAllowed("content/{$model['name']}/manage")) {
                $app->response->status = 401;
                return ['error' => 'Permission denied'];
            }

            try {
                $result = $app->module('content')->saveModel($model['name'], $model);
                return $result;
            } catch (\Throwable $e) {
                $app->response->status = 500;
                return ['error' => $e->getMessage()];
            }
        }
    ]);

    $restApi->addEndPoint('/models/remove', [
        'POST' => function($params, $app) {

            $name = $app->param('name');

            if (!$name || !trim($name)) {
                $app->response->status = 412;
                return ['error' => 'Model name is missing'];
            }

            if (!$app->helper('acl')->isAllowed("content/:models/manage")) {
                $app->response->status = 401;
                return ['error' => 'Permission denied'];
            }

            try {
                $app->module('content')->removeModel($name);
                return ['success' => true];
            } catch (\Throwable $e) {
                $app->response->status = 500;
                return ['error' => $e->getMessage()];
            }
        }
    ]);
});

// ---------------------------------------------------------------------------
// 8. Admin UI (menu entry + screen)
// ---------------------------------------------------------------------------

// The application's API key must exist in the datastore, not only in the cache
// Cockpit builds from it. Checked on admin load because that is cheap, happens
// often enough, and is where somebody would be looking if reads were failing.
$this->on('app.admin.init', function() {
    $this->helper('webapp')->ensureApiKey();
    include(__DIR__.'/admin.php');
});
