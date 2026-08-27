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
 *
 * $model and $item name what changed, straight from the content.item.save
 * event. They travel as a JSON body so an app serving more than one cached
 * page can invalidate precisely what the edit affected instead of dropping
 * everything. Both are optional and the body is additive: an older Go app
 * ignores it and purges its home page exactly as before.
 */
$purge = function($model = null, $item = null) {

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

    // Replica calls this helper with no arguments, and the item is an array
    // when it arrives from content.item.save. Accept a bare id too, so the
    // admin screens can name a single entry.
    $id = is_array($item) ? ($item['_id'] ?? null) : $item;

    $body = json_encode(array_filter([
        'model' => $model ? (string)$model : null,
        'id'    => $id ? (string)$id : null,
    ], fn($v) => $v !== null));

    $headers = ['Content-Type: application/json'];

    if ($token) {
        $headers[] = 'X-Api-Key: ' . $token;
    }

    $ch = curl_init($endpoint);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $body,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 5,
        CURLOPT_CONNECTTIMEOUT => 3,
        CURLOPT_HTTPHEADER     => $headers,
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

// Hook regular CMS saves (admin publish / save). The event hands over the
// model name and the saved item, which travel to the app as the purge body.
$this->on('content.item.save', function($model, $item) use ($purge) {
    $purge($model, $item);
});

// Expose for Replica: $app->helper('cachepurge')() after replication.
$this->helpers['cachepurge'] = $purge;
