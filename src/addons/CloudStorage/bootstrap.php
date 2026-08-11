<?php
/**
 * CloudStorage - S3 / S3-compatible storage for Cockpit core (not the Pro
 * addon). Reads the same `cloudStorage` config shape the Cockpit Pro docs
 * document, but is implemented against the Flysystem adapters the core image
 * ships in lib/vendor/ (league/flysystem-aws-s3-v3 + aws/aws-sdk-php), so no
 * composer install or Pro license is needed.
 *
 * Config (cockpit/config.php):
 *
 *   'cloudStorage' => [
 *       'uploads' => [
 *           'url' => getenv('S3_URL'),              // S3-compatible endpoint; leave unset for AWS
 *           'key' => getenv('S3_KEY'),
 *           'secret' => getenv('S3_SECRET'),
 *           'region' => getenv('S3_REGION') ?: 'auto',
 *           'bucket' => getenv('S3_BUCKET'),
 *           'prefix' => getenv('S3_PREFIX') ?: '',
 *           'visibility' => 'public',               // optional, default public
 *       ],
 *   ],
 *
 * Notes:
 * - A custom `url` implies path-style addressing, which is what MinIO,
 *   DigitalOcean Spaces, Cloudflare R2 and Backblaze B2 expect. AWS S3 uses
 *   virtual-hosted addressing (no `url`).
 * - When `uploads` is configured the `#uploads` storage is mirrored too:
 *   Cockpit writes generated thumbnails to `#uploads://`.
 * - `type: azure` is not supported on core (the adapter is not bundled) and
 *   is skipped.
 */

$this->on('app.filestorage.init', function (&$storages) {

    $config = $this->cloudStorage ?? [];

    foreach ($config as $name => $opts) {

        if (isset($opts['type']) && $opts['type'] !== 's3') {
            continue; // azure requires the separate storage-blob-flysystem adapter
        }

        if (empty($opts['bucket']) || empty($opts['key']) || empty($opts['secret'])) {
            continue; // not configured for this environment; keep the default storage
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
        ]);

        $s3 = [
            'adapter'    => 'League\Flysystem\AwsS3V3\AwsS3V3Adapter',
            'args'       => [
                $client,
                $opts['bucket'],
                $opts['prefix'] ?? '',
            ],
            'visibility' => $opts['visibility'] ?? 'public',
        ];

        // Preserve mount/url from the bootstrap defaults so serving through
        // the CMS and the /storage/uploads proxy keeps working.
        $existing = $storages[$name] ?? [];
        $storages[$name] = array_merge($existing, $s3);

        if ($name === 'uploads') {
            $thumb = $storages['#uploads'] ?? [];
            $storages['#uploads'] = array_merge($thumb, $s3);
        }
    }
});
