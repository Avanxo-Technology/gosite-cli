<?php
/**
 * AssetPathFix - Strip leading slash from asset paths before they reach storage.
 *
 * Cockpit's CloudStorage addon stores asset path fields with a leading slash
 * (e.g. /2026/08/15/file.webp). When the admin JS builds asset URLs it
 * concatenates the S3 public URL + / + path, producing a double-slash that
 * breaks previews:
 *
 *   https://bucket.s3.amazonaws.com//2026/08/15/file.webp
 *
 * Hooking into assets.asset.upload and ltrim-ing the slash fixes both the
 * Flysystem write ($path) and the MongoDB document ($asset['path']). The
 * event fires after $asset['path'] = $path is assigned, so both must be
 * cleaned. All consumers already handle paths without the leading slash.
 */

$this->on('assets.asset.upload', function (&$asset, &$_meta, &$opts, &$file, &$path) {
    if (is_string($path) && str_starts_with($path, '/')) {
        $path = ltrim($path, '/');
    }
    if (is_array($asset) && isset($asset['path']) && str_starts_with($asset['path'], '/')) {
        $asset['path'] = ltrim($asset['path'], '/');
    }
});
