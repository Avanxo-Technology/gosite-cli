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
 * expects in the X-Api-Key header. In non-development environments without a
 * token the endpoint answers 503 - which surfaces here as a logged failure,
 * naming where to point the blame.
 */

/**
 * POSTs to the Go app's cache-purge endpoint. A failed purge is logged with
 * its HTTP status or transport error so stale cache after an outage can be
 * diagnosed - but it never blocks the CMS save or replication run that
 * triggered it.
 */
$purge = function() {

    static $disabledLogged = false;

    $url = getenv('APP_URL');

    if (!$url) {
        // One notice is enough: purging stays off until APP_URL is set.
        if (!$disabledLogged) {
            $disabledLogged = true;
            error_log('[cachepurge] disabled: APP_URL is not set.');
        }
        return;
    }

    $endpoint = rtrim($url, '/') . '/cache/purge';
    $token    = getenv('COCKPIT_API_TOKEN') ?: '';

    $ch = curl_init($endpoint);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_HTTPHEADER     => $token ? ['X-Api-Key: ' . $token] : [],
    ]);
    curl_exec($ch);

    $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $error  = curl_error($ch);

    curl_close($ch);

    if ($error !== '') {
        error_log("[cachepurge] {$endpoint} transport error: {$error}");
    } elseif ($status < 200 || $status >= 300) {
        error_log("[cachepurge] {$endpoint} failed with HTTP {$status}");
    }
};

// Hook regular CMS saves (admin publish / save).
$this->on('content.item.save', $purge);

// Expose for Replica: $app->helper('cachepurge')() after replication.
$this->helpers['cachepurge'] = $purge;
