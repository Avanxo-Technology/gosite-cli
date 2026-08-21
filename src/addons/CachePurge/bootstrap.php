<?php
/**
 * CachePurge - Purges the Go app cache when Cockpit content changes.
 *
 * Two triggers:
 *   1. content.item.save — fires on every Cockpit save/publish via the admin.
 *   2. Replica finish() — after a push or pull writes items via dataStorage.
 *      Replica calls $app->helper('cachepurge') directly because its writes
 *      bypass content->saveItem() and do not fire the event above.
 *
 * The app URL and API key come from the CMS container's environment (set in
 * docker-compose.yml): APP_URL is the internal Docker network address for
 * the Go app, and COCKPIT_API_TOKEN is the shared secret the purge endpoint
 * expects in the X-Api-Key header.
 *
 * In development COCKPIT_API_TOKEN is empty and the purge endpoint skips
 * token validation, so the POST succeeds without a header.
 */

/**
 * POSTs to the Go app's cache-purge endpoint. Silently swallows errors:
 * a failed purge is never worth blocking a CMS save or a replication run.
 */
$purge = function() {

    $url = getenv('APP_URL');
    if (!$url) return;

    $token = getenv('COCKPIT_API_TOKEN') ?: '';

    $ch = curl_init(rtrim($url, '/') . '/cache/purge');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_HTTPHEADER     => $token ? ['X-Api-Key: ' . $token] : [],
    ]);
    curl_exec($ch);
    curl_close($ch);
};

// Hook regular CMS saves (admin publish / save).
$this->on('content.item.save', $purge);

// Expose for Replica: $app->helper('cachepurge')() after replication.
$this->helpers['cachepurge'] = $purge;
