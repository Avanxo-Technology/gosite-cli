<?php

namespace Replica\Helper;

use Replica\Model\Target;

/**
 * HTTP client for a remote Cockpit instance.
 *
 * Two transports, chosen by probing the remote once:
 *
 *   peer - the remote also runs this addon and exposes /api/replica/*.
 *          Full fidelity: model definitions, and items with their original
 *          _id/_created/_modified preserved exactly.
 *
 *   core - plain Cockpit. Only /api/content/* exists, and it is lossy:
 *            - the POST handler strips every key that is not _id, _state or a
 *              declared model field, so _created/_modified are assigned by the
 *              remote at write time;
 *            - a new entry cannot keep its _id, so Replica records the id the
 *              remote minted and reuses it next time (see pushItems and
 *              Helper\Replica::idMap);
 *            - every read endpoint hard-codes filter._state = 1, so unpublished
 *              remote entries are invisible and cannot be verified;
 *            - model definitions cannot be transferred at all.
 *
 * Both transports authenticate with the api-key header, which the core reads
 * in modules/App/api.php as HTTP_API_KEY.
 */
class Client extends \Lime\Helper {

    const TRANSPORT_PEER = 'peer';
    const TRANSPORT_CORE = 'core';

    protected ?Target $target = null;
    protected ?string $transport = null;

    public function forTarget(Target $target): static {

        $client = new static($this->app);
        $client->target = $target;

        return $client;
    }

    public function baseUrl(): string {
        return $this->target?->baseUrl ?? '';
    }

    /**
     * Detects which transport the remote supports. Cached per client instance.
     */
    public function transport(): string {

        if ($this->transport !== null) {
            return $this->transport;
        }

        $response = $this->request('GET', '/api/replica/manifest');

        /*
         * status 0 means curl never got an answer - wrong host, DNS failure,
         * connection refused, timeout. Falling through to "core" there would
         * label an unreachable instance as a working plain Cockpit and only
         * fail later, with the log claiming a transport that was never used.
         */
        if ($response['status'] === 0) {
            throw new \Exception('Target unreachable at '.$this->baseUrl().': '.($response['error'] ?: 'no response'));
        }

        $this->transport = ($response['status'] === 200 && isset($response['body']['replica']))
            ? self::TRANSPORT_PEER
            : self::TRANSPORT_CORE;

        return $this->transport;
    }

    public function isPeer(): bool {
        return $this->transport() === self::TRANSPORT_PEER;
    }

    /**
     * Reachability check used by the UI and by "targets list".
     */
    public function ping(): array {

        $response = $this->request('GET', '/api/replica/manifest');

        if ($response['status'] === 200 && isset($response['body']['replica'])) {
            return [
                'ok'        => true,
                'transport' => self::TRANSPORT_PEER,
                'version'   => $response['body']['replica'],
                'models'    => count($response['body']['models'] ?? []),
            ];
        }

        /*
         * Not a peer - check the plain content API. There is no core endpoint
         * that answers 200 without naming a model: /api/content/items replies
         * 412 "<models> parameter is missing" once authenticated, and 412
         * "Authentication failed" when the key is rejected. That difference is
         * the reachability signal, so do not treat every 412 as a failure.
         */
        $probe = $this->request('GET', '/api/content/items');
        $error = is_array($probe['body'] ?? null) ? ($probe['body']['error'] ?? '') : '';

        if ($probe['status'] === 200 || ($probe['status'] > 0 && $error && !str_contains($error, 'Authentication failed'))) {
            return ['ok' => true, 'transport' => self::TRANSPORT_CORE, 'version' => null];
        }

        return [
            'ok'        => false,
            'transport' => null,
            'error'     => $error
                ?: ($probe['error'] ?: ($response['error'] ?: 'HTTP '.($probe['status'] ?: $response['status']))),
        ];
    }

    // ------------------------------------------------------------------ read

    /**
     * Model definitions available remotely. Peer transport only.
     */
    public function remoteModels(): array {

        if (!$this->isPeer()) {
            return [];
        }

        $response = $this->request('GET', '/api/replica/models');

        return $response['status'] === 200 ? ($response['body']['models'] ?? []) : [];
    }

    /**
     * Names of the content models the remote holds (collections and
     * singletons), which is what a pull can sync. Peer transport only.
     */
    public function remoteContentModels(): array {

        if ($this->isPeer()) {

            $response = $this->request('GET', '/api/replica/manifest');
            $models   = $response['body']['models'] ?? [];

            return array_column(array_filter(
                $models,
                fn($m) => in_array($m['type'] ?? '', ['collection', 'singleton'])
            ), 'name');
        }

        // The core exposes no model listing; the operator selects names manually.
        return [];
    }

    /**
     * Reads every item of a model, paging so a large collection does not have
     * to fit in one response.
     *
     * $type only matters for a core target: a singleton has no list endpoint,
     * so it is read through the singular /api/content/item/{model} and wrapped
     * as a one-element batch. Peer transport ignores it - the remote branches
     * on its own model definitions.
     */
    public function fetchItems(string $model, int $chunk = 200, string $type = ''): array {

        $items = [];
        $skip  = 0;

        while (true) {

            if ($this->isPeer()) {
                $response = $this->request('GET', "/api/replica/items/{$model}", [
                    'limit' => $chunk,
                    'skip'  => $skip,
                ]);
                $batch = $response['body']['items'] ?? [];
            } elseif ($type === 'singleton') {

                // Singular endpoint: the body IS the singleton document. The
                // remote replies 404 when the model has no content yet, which
                // simply means there is nothing to copy.
                $response = $this->request('GET', "/api/content/item/{$model}");
                $doc      = is_array($response['body'] ?? null) ? $response['body'] : null;
                $batch    = $doc ? [$doc] : [];

                if ($response['status'] !== 200 && $response['status'] !== 404) {
                    throw new \Exception("Remote read of '{$model}' failed: ".($response['error'] ?: 'HTTP '.$response['status']));
                }
            } else {

                $response = $this->request('GET', "/api/content/items/{$model}", [
                    'limit'    => $chunk,
                    'skip'     => $skip,
                    'populate' => 0,
                ]);

                /*
                 * Shape depends on the query: modules/Content/api.php returns a
                 * bare array normally, but wraps it as {data, meta} when skip
                 * AND limit are both present - which is always, here. Reading
                 * the wrapper as if it were the list yields two "items" with no
                 * _id, which silently defeats every id comparison downstream.
                 *
                 * Note this endpoint also forces filter._state = 1, so a core
                 * remote only ever exposes its published entries.
                 */
                $body  = $response['body'] ?? null;
                $batch = [];

                if (is_array($body)) {
                    $batch = array_is_list($body) ? $body : (is_array($body['data'] ?? null) ? $body['data'] : []);
                }
            }

            if ($response['status'] !== 200) {
                throw new \Exception("Remote read of '{$model}' failed: ".($response['error'] ?: 'HTTP '.$response['status']));
            }

            if (!count($batch)) break;

            $items = array_merge($items, $batch);

            if (count($batch) < $chunk) break;

            $skip += $chunk;
        }

        return $items;
    }

    // ----------------------------------------------------------------- write

    /**
     * Upserts model definitions remotely. Peer transport only.
     */
    public function pushModels(array $models, string $mode): array {
        if (!$this->isPeer()) {
            throw new \Exception('Remote does not run Replica: model definitions cannot be transferred.');
        }

        $response = $this->request('POST', '/api/replica/models', [
            'models' => $models,
            'mode'   => $mode,
        ]);

        if ($response['status'] !== 200) {
            throw new \Exception('Remote model write failed: '.($response['error'] ?: 'HTTP '.$response['status']));
        }

        return $response['body'] ?? [];
    }

    /**
     * Upserts items remotely.
     *
     * Peer: one batched call, timestamps preserved, merge resolved remotely.
     * Core: one POST per item, and _created/_modified are lost (see class doc).
     */
    public function pushItems(string $model, array $items, string $mode, array $idMap = [], string $type = ''): array {

        if ($this->isPeer()) {

            $response = $this->request('POST', "/api/replica/items/{$model}", [
                'items' => $items,
                'mode'  => $mode,
            ]);

            if ($response['status'] !== 200) {
                throw new \Exception("Remote write of '{$model}' failed: ".($response['error'] ?: 'HTTP '.$response['status']));
            }

            return $response['body'] ?? [];
        }

        $result = [
            'created' => 0, 'updated' => 0, 'skipped' => 0, 'errors' => 0,
            'messages' => [], 'unverified' => 0,
            // Pairs the caller should persist; see Helper\Replica::idMap().
            'idMap' => [], 'idMapStale' => [],
        ];

        /*
         * The remote index is needed in BOTH modes, not just merge, because the
         * core's POST behaves in three different ways:
         *
         *   no _id               -> creates, assigning its own _id
         *   existing _id         -> updates correctly
         *   non-existent _id     -> answers 200 and echoes the document back
         *                           but writes NOTHING (its saveItem hits
         *                           dataStorage->save(), which cannot upsert)
         *
         * Sending our _id blindly would therefore silently lose every new
         * entry while reporting success.
         */
        $remote = [];

        foreach ($this->fetchItems($model, 200, $type) as $item) {
            if (isset($item['_id'])) $remote[$item['_id']] = $item;
        }

        foreach ($items as $item) {

            $id = $item['_id'] ?? null;

            /*
             * Which remote entry does this one correspond to?
             *   1. the same _id, when a previous peer sync or a manual import
             *      happened to keep it;
             *   2. otherwise whatever the remote minted for it last time, as
             *      remembered in the id map.
             * A mapping pointing at an entry that is gone is stale: drop it and
             * treat this as a create, or the POST would silently do nothing.
             */
            $remoteId    = null;
            $unverifiable = false;

            if ($id && isset($remote[$id])) {
                $remoteId = $id;
            } elseif ($id && isset($idMap[$id])) {

                $remoteId = $idMap[$id];

                /*
                 * The index only holds published entries: every core read
                 * endpoint hard-codes filter._state = 1, so an unpublished
                 * remote entry is invisible and indistinguishable from a
                 * deleted one. Trusting the mapping is the lesser evil -
                 * treating it as stale would recreate the entry on every single
                 * run and pile up duplicates. The write is still safe: an id
                 * that truly no longer exists makes the core POST a no-op.
                 */
                $unverifiable = !isset($remote[$remoteId]);
            }

            if ($remoteId && $mode === 'merge') {

                if ((int)($remote[$remoteId]['_modified'] ?? 0) > (int)($item['_modified'] ?? 0)) {
                    $result['skipped']++;
                    $result['messages'][] = "skip {$id}: destination is newer";
                    continue;
                }
            }

            $payload = $item;

            if ($remoteId) {
                $payload['_id'] = $remoteId;
            } else {
                // Let the remote mint the id: keeping ours would no-op.
                unset($payload['_id']);
            }

            $response = $this->request('POST', "/api/content/item/{$model}", ['data' => $payload]);

            if ($response['status'] !== 200) {
                $result['errors']++;
                $result['messages'][] = 'error '.($id ?: '?').': '.($response['error'] ?: 'HTTP '.$response['status']);
                continue;
            }

            if ($remoteId) {

                $result['updated']++;

                $note = $remoteId === $id ? "update {$id}" : "update {$id} (remote {$remoteId})";

                if ($unverifiable) {
                    $note .= ' [unverified: remote entry is not published, so the core API cannot confirm it]';
                    $result['unverified']++;
                }

                $result['messages'][] = $note;
                continue;
            }

            $newId = is_array($response['body'] ?? null) ? ($response['body']['_id'] ?? null) : null;

            $result['created']++;

            if ($id && $newId) {
                $result['idMap'][$id] = $newId;
                $result['messages'][] = "create {$id} -> remote {$newId}, mapping remembered";
            } else {
                $result['messages'][] = 'create '.($id ?: '?').' (remote id unknown, cannot map)';
            }
        }

        return $result;
    }

    // ----------------------------------------------------------------- assets

    /**
     * The remote's current asset metadata and folder definitions. Peer
     * transport only; used to plan a push and to list what a pull would copy.
     *
     * @return array{assets:array, folders:array}
     */
    public function remoteAssetState(): array {

        if (!$this->isPeer()) {
            return ['assets' => [], 'folders' => []];
        }

        $response = $this->request('GET', '/api/replica/assets');

        if ($response['status'] !== 200) {
            return ['assets' => [], 'folders' => []];
        }

        return [
            'assets'  => $response['body']['assets'] ?? [],
            'folders' => $response['body']['folders'] ?? [],
        ];
    }

    /**
     * Fetches the original file bytes of every asset and attaches them as
     * base64 fileData. Metadata that already exists locally still gets its
     * file, because the merge decision happens at apply time.
     */
    public function attachRemoteFiles(array $assets): array {

        foreach ($assets as &$asset) {

            $id = $asset['_id'] ?? null;

            if (!$id) continue;

            $response = $this->request('GET', "/api/replica/assets/file/{$id}");

            if ($response['status'] === 200 && isset($response['body']['fileData'])) {
                $asset['fileData'] = $response['body']['fileData'];
            }
        }

        return $assets;
    }

    /**
     * Upserts assets and folders remotely. Peer transport only. The payload
     * already carries the file bytes (base64 fileData), attached by the caller
     * through Helper\Replica::attachAssetData().
     */
    public function pushAssets(array $payload, string $mode): array {

        if (!$this->isPeer()) {
            throw new \Exception('Remote does not run Replica: assets cannot be transferred.');
        }

        $response = $this->request('POST', '/api/replica/assets', [
            'assets'  => $payload['assets'] ?? [],
            'folders' => $payload['folders'] ?? [],
            'mode'    => $mode,
        ]);

        if ($response['status'] !== 200) {
            throw new \Exception('Remote asset write failed: '.($response['error'] ?: 'HTTP '.$response['status']));
        }

        return $response['body'] ?? [];
    }

    // ------------------------------------------------------------------ http

    /**
     * @return array{status:int, body:mixed, error:?string}
     */
    public function request(string $method, string $path, array $payload = []): array {

        $url = $this->baseUrl().$path;

        if ($method === 'GET' && count($payload)) {
            $url .= (str_contains($url, '?') ? '&' : '?').http_build_query($payload);
        }

        $headers = [
            // The only place the secret is read.
            'api-key: '.($this->target?->apiKey() ?? ''),
            'Accept: application/json',
        ];

        $ch = curl_init($url);

        $options = [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => $this->target?->timeout ?? Target::DEFAULT_TIMEOUT,
            CURLOPT_CONNECTTIMEOUT => 10,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CUSTOMREQUEST  => $method,
        ];

        if ($method !== 'GET') {
            $body = json_encode($payload);
            $headers[] = 'Content-Type: application/json';
            $headers[] = 'Content-Length: '.strlen($body);
            $options[CURLOPT_POSTFIELDS] = $body;
        }

        $options[CURLOPT_HTTPHEADER] = $headers;

        curl_setopt_array($ch, $options);

        $raw    = curl_exec($ch);
        $status = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error  = curl_error($ch);

        curl_close($ch);

        if ($error) {
            return ['status' => 0, 'body' => null, 'error' => $error];
        }

        $body = json_decode((string)$raw, true);

        if (json_last_error() !== JSON_ERROR_NONE) {
            $body = $raw;
        }

        $message = null;

        if ($status >= 400) {
            $message = is_array($body) && isset($body['error'])
                ? (is_string($body['error']) ? $body['error'] : json_encode($body['error']))
                : 'HTTP '.$status;
        }

        return ['status' => $status, 'body' => $body, 'error' => $message];
    }
}
