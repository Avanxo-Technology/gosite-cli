<?php

// Cockpit configuration, merged over the defaults in bootstrap.php.
// Used in both local development and production: local mounts this into the
// CMS container; deployment bakes it into the image via Dockerfile.cms.
//
// Values are read with getenv() directly. Cockpit's DotEnv ${VAR} resolution
// does not run reliably on all images for values baked into config.php.

$mongoUser = (string)getenv('MONGO_USER');
$mongoPass = (string)getenv('MONGO_PASSWORD');
$mongoHost = getenv('MONGO_HOST') ?: 'localhost';
$mongoPort = getenv('MONGO_PORT') ?: '27017';

// Credentials are optional: the shared gosite-mongo runs without auth, and an
// empty user:pass@ in the URI makes the Mongo driver attempt SCRAM auth and
// fail with "Authentication failed". Only append credentials when both exist.
$mongoAuth = ($mongoUser !== '' && $mongoPass !== '')
    ? rawurlencode($mongoUser).':'.rawurlencode($mongoPass).'@'
    : '';

// Storage engine chosen at scaffold time: 'mongodb' (default, the shared infra
// or the project's own Mongo) or 'local' (mongolite files inside the
// container's storage/data - handy for throwaway tests with no infra).
$useLocal = getenv('COCKPIT_DATABASE') === 'local';
$mongoDb  = getenv('MONGO_DB') ?: '__PROJECT__';

$config = [

    // Content storage. MongoDB: models and entries live on the shared infra
    // (gosite-mongo in dev, own Mongo in prod), never in local files. Local:
    // mongolite sqlite under storage/data, fully self-contained.
    'database' => $useLocal
        ? [
            'server' => 'mongolite:///var/www/html/storage/data',
            'options' => ['db' => $mongoDb],
            'driverOptions' => [],
        ]
        : [
            'server' => 'mongodb://'.$mongoAuth.$mongoHost.':'.$mongoPort,
            'options' => ['db' => $mongoDb],
            'driverOptions' => [],
        ],

    // Store content model definitions alongside the data (in MongoDB when not
    // in local mode, in storage/content files when local), never as a mix.
    'content' => [
        'models' => [
            'storage' => $useLocal ? 'files' : 'database',
        ],
    ],

    // App memory/options: on the shared infrastructure instead of Cockpit's
    // default local redislite file (storage/data/app.memory.sqlite). Cockpit
    // core's memory driver only supports redislite or Redis (not MongoDB), so
    // the infra Redis is used - dev on the shared gosite-redis (DB 1, off the
    // app's page-cache DB 0), production on the project's own redis service. A
    // per-project key prefix stops projects sharing the infra Redis from
    // colliding. In local mode memory stays in the redislite file.
    'memory' => $useLocal
        ? ['server' => 'redislite:///var/www/html/storage/data/app.memory.sqlite', 'options' => []]
        : [
            'server' => getenv('COCKPIT_MEMORY_SERVER') ?: 'redis://gosite-redis:6379',
            'options' => [
                'auth'     => parse_url(getenv('COCKPIT_MEMORY_SERVER') ?: 'redis://localhost')['pass'] ?? null,
                'database' => 1,
                'prefix'   => $mongoDb.':',
            ],
        ],

    // The image ships a hardcoded, publicly known key. Overriding it is what
    // stops anyone from forging a session against a deployed site.
    'sec-key' => getenv('COCKPIT_SEC_KEY') ?: '__COCKPIT_SEC_KEY__',

    'session' => [
        'name' => '__PROJECT__',
    ],

    // Forms addon: number of trusted reverse-proxy hops in front of the CMS.
    // Every gosite site sits behind exactly one Traefik hop, so client
    // identity for the rate limiter is taken one entry from the RIGHT of
    // X-Forwarded-For (the entry this proxy observed), never the leftmost one,
    // which clients can forge. Set 0 for direct, unproxied deployments.
    //
    // Personal data in submissions (ip, userAgent):
    //   personal_data_retention - seconds until both fields are cleared from
    //     stored submissions by the addon's maintenance path; everything else
    //     in the submission is preserved. Default: 90 days. Set 0 to keep
    //     them indefinitely ('gosite doctor' flags that as a finding).
    //   collect_personal_data  - set false to never store them at all. The
    //     rate limit is unaffected: it reads the client address at request
    //     time and never needs the stored copy.
    'forms' => [
        'trustedProxies' => 1,
        'personal_data_retention' => 7776000, // 90 days
        'collect_personal_data'   => true,
    ],
];

// S3-compatible asset storage (MinIO in dev, AWS/Backblaze/R2 in prod).
// Enabled per environment with STORAGE_ADAPTER=s3; the CloudStorage addon
// reads this config and wires uploads to the Flysystem S3 adapter the core
// image already ships (no composer step, no Pro license). The keys match the
// Cockpit Pro CloudStorage docs, so the config stays valid if the real Pro
// addon is ever installed.
if (getenv('STORAGE_ADAPTER') === 's3') {
    $config['cloudStorage'] = [
        'uploads' => [
            'url'    => getenv('S3_URL') ?: null,
            'key'    => getenv('S3_KEY'),
            'secret' => getenv('S3_SECRET'),
            'region' => getenv('S3_REGION') ?: 'auto',
            'bucket' => getenv('S3_BUCKET'),
            'prefix' => getenv('S3_PREFIX') ?: '',
            // null = bucket policy handles access (required for "Bucket owner
            // enforced" buckets where ACLs are disabled). Set S3_ACL=yes to
            // switch to public-read ACL.
            'visibility' => getenv('S3_ACL') === 'yes' ? 'public' : null,
            // Browser-reachable base for asset URLs: https://minio.<TLD> for
            // local MinIO, a CDN or bucket endpoint in production. When unset
            // the addon keeps Cockpit's own /storage/uploads proxy (which only
            // works while files stay on disk).
            'public_url' => getenv('S3_PUBLIC_URL') ?: '',
        ],
    ];

    // Generated thumbnails go to S3 too, so the browser can load them through
    // the public URL. The default `tmp://thumbs` storage resolves to a disk
    // path because docs_root is unset on this image, and pointing it at the
    // local `#uploads` mount would die with the S3 adapter. Requires the
    // public_url above to be set.
    $config['assets']['storage'] = 'uploads://thumbs';
}

return $config;
