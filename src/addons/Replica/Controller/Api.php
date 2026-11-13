<?php

namespace Replica\Controller;

/**
 * Admin API bound at /replica/api - session authenticated, used by the screen.
 *
 * Extends App\Controller\Base rather than App\Controller\App so a failed auth
 * returns JSON instead of redirecting an XHR to the login page; auth and CSRF
 * are enforced explicitly, mirroring App\Controller\Authenticated.
 */
class Api extends \App\Controller\Base {

    /**
     * GET /replica/api/targets  -> targets (secrets masked) + local collections
     */
    public function targets() {

        if (!$this->guard()) return false;

        $replica = $this->helper('replica');

        // Target::jsonSerialize() masks the api key, so this cannot leak it.
        return [
            'targets'     => $replica->targets(),
            'collections' => $replica->localModels(),
        ];
    }

    /**
     * POST /replica/api/target  (CSRF) -> create or update
     */
    public function target() {

        if (!$this->guard() || !$this->csrf()) return false;

        try {
            $target = $this->helper('replica')->saveTarget((array)$this->param('target', []));
        } catch (\Throwable $e) {
            $this->app->response->status = 412;
            return ['success' => false, 'error' => $e->getMessage()];
        }

        return ['success' => true, 'target' => $target];
    }

    /**
     * POST /replica/api/remove/{id}  (CSRF)
     */
    public function remove($id = null) {

        if (!$this->guard() || !$this->csrf()) return false;

        if (!$id || !$this->helper('replica')->removeTarget($id)) {
            $this->app->response->status = 404;
            return ['success' => false, 'error' => 'Target not found.'];
        }

        return ['success' => true];
    }

    /**
     * GET /replica/api/ping/{id} -> reachability + which transport applies
     */
    public function ping($id = null) {

        if (!$this->guard()) return false;

        $target = $this->helper('replica')->target((string)$id);

        if (!$target) {
            $this->app->response->status = 404;
            return ['ok' => false, 'error' => 'Target not found.'];
        }

        return $this->helper('replica')->client($target)->ping();
    }

    /**
     * GET /replica/api/diff/{id}?model=  -> read-only comparison, per model
     *
     * A target that cannot be reached answers 502 with the reason in `error`.
     */
    public function diff($id = null) {

        if (!$this->guard()) return false;

        $replica = $this->helper('replica');
        $target  = $replica->target((string)$id);

        if (!$target) {
            $this->app->response->status = 404;
            return ['success' => false, 'error' => 'Target not found.'];
        }

        try {
            return $replica->diff($target, $this->param('model', null) ?: null);
        } catch (\Throwable $e) {
            $this->app->response->status = 502;
            return ['success' => false, 'error' => $e->getMessage()];
        }
    }

    /**
     * POST /replica/api/run/{id}  (CSRF)
     * body: direction=push|pull, mode=mirror|merge, dryRun, verbose, model, ids (push only)
     */
    public function run($id = null) {

        if (!$this->guard() || !$this->csrf()) return false;

        $replica = $this->helper('replica');
        $target  = $replica->target((string)$id);

        if (!$target) {
            $this->app->response->status = 404;
            return ['success' => false, 'error' => 'Target not found.'];
        }

        if (!$target->enabled) {
            $this->app->response->status = 412;
            return ['success' => false, 'error' => 'Target is disabled.'];
        }

        $direction = $this->param('direction', 'push') === 'pull' ? 'pull' : 'push';

        $options = [
            'mode'    => $this->param('mode', 'merge'),
            'dryRun'  => filter_var($this->param('dryRun', false), FILTER_VALIDATE_BOOLEAN),
            'verbose' => filter_var($this->param('verbose', false), FILTER_VALIDATE_BOOLEAN),
            'model'   => $this->param('model', null) ?: null,
        ];

        $ids = $this->param('ids', null);

        if ($ids !== null) {

            if (!is_array($ids) || count(array_filter($ids, fn($entry) => !is_string($entry)))) {
                $this->app->response->status = 412;
                return ['success' => false, 'error' => 'ids must be a list of entry ids.'];
            }

            // Selections only narrow a push; a pull always takes the whole model.
            if ($direction === 'push') $options['ids'] = $ids;
        }

        // A run with assets can outlast the browser's patience. Finish it
        // anyway: stopping halfway leaves the destination half-copied.
        ignore_user_abort(true);
        @set_time_limit(0);

        $result = $direction === 'pull'
            ? $replica->pull($target, $options)
            : $replica->push($target, $options);

        return ['success' => $result['errors'] === 0, 'result' => $result];
    }

    /**
     * POST /replica/api/toggle/{id}  (CSRF)
     *
     * Body may carry enabled=true|false; omitting it flips the current state.
     */
    public function toggle($id = null) {

        if (!$this->guard() || !$this->csrf()) return false;

        $enabled = $this->param('enabled', null);

        if ($enabled !== null) {
            $enabled = filter_var($enabled, FILTER_VALIDATE_BOOLEAN);
        }

        $target = $this->helper('replica')->toggleTarget((string)$id, $enabled);

        if (!$target) {
            $this->app->response->status = 404;
            return ['success' => false, 'error' => 'Target not found.'];
        }

        return ['success' => true, 'enabled' => $target->enabled, 'target' => $target];
    }

    /**
     * GET /replica/api/log?page=&target=
     */
    public function log() {

        if (!$this->guard()) return false;

        return $this->helper('replica')->log(
            (int)$this->param('page', 1),
            (int)$this->param('limit', 25),
            $this->param('target', null) ?: null
        );
    }

    /**
     * GET /replica/api/protected -> every local content model with its protection state
     *
     * POST /replica/api/protected  (CSRF) body: models=string[], the full desired list.
     * Models in the list become protected, every other local model is unprotected.
     * Lime routes by method name, so the URL segment `protected` calls this method.
     */
    public function protected() {

        if (!$this->guard()) return false;

        if ($this->app->request->method === 'POST') {

            if (!$this->csrf()) return false;

            return $this->saveProtection();
        }

        return ['models' => $this->protectionState()];
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Applies the desired protected list. Only real changes reach the activity log,
     * because the protect helpers are idempotent.
     */
    protected function saveProtection(): array {

        $requested = $this->param('models', []);

        if (!is_array($requested) || count(array_filter($requested, fn($m) => !is_string($m)))) {
            $this->app->response->status = 412;
            return ['success' => false, 'error' => 'models must be a list of content model names.'];
        }

        $requested = array_values(array_unique($requested));
        $replica   = $this->helper('replica');
        $local     = array_column($replica->localModels(), 'name');
        $unknown   = array_values(array_diff($requested, $local));

        if (count($unknown)) {
            $this->app->response->status = 412;
            return ['success' => false, 'error' => 'Unknown content model: '.implode(', ', $unknown)];
        }

        $by      = $this->currentUserName();
        $changed = [];

        foreach ($local as $model) {

            $did = in_array($model, $requested, true)
                ? $replica->protect($model, $by)
                : $replica->unprotect($model, $by);

            if ($did) $changed[] = $model;
        }

        return ['success' => true, 'changed' => $changed, 'models' => $this->protectionState()];
    }

    /**
     * Local content models with their protection state. `by` and `_created` only
     * appear for protected models, taken from the REPLICA_PROTECTED document.
     */
    protected function protectionState(): array {

        $docs   = $this->helper('replica')->protectionRecords();
        $models = [];

        foreach ($this->helper('replica')->localModels() as $model) {

            $doc   = $docs[$model['name']] ?? null;
            $entry = $model + ['protected' => (bool)$doc];

            if ($doc) {
                $entry['by']       = $doc['by'] ?? null;
                $entry['_created'] = $doc['_created'] ?? null;
            }

            $models[] = $entry;
        }

        return $models;
    }

    protected function currentUserName(): ?string {

        $auth = $this->helper('auth');

        return $auth->getUser('name') ?: $auth->getUser('user') ?: null;
    }

    protected function guard(): bool {

        $user = $this->helper('auth')->getUser();

        if (!$user) {
            $this->stop(['success' => false, 'error' => 'Authentication required.'], 401);
            return false;
        }

        // Authenticated::initialize() normally does this; acl reads from it.
        $this->app->set('user', $user);

        if (!$this->helper('acl')->isAllowed('replica/manage')) {
            $this->stop(['success' => false, 'error' => 'Permission denied.'], 403);
            return false;
        }

        return true;
    }

    /**
     * Same check App\Controller\Authenticated::hasValidCsrfToken() performs.
     */
    protected function csrf(): bool {

        $token = $this->app->param('xcsrftoken', $this->app->request->headers['X-Csrf-Token'] ?? '');

        if ($this->helper('csrf')->isValid('app.csrf', $token, true)) {
            return true;
        }

        $this->stop(['success' => false, 'error' => 'Invalid CSRF token.'], 412);

        return false;
    }

    protected function json($data): string {
        header('Content-Type: application/json; charset=utf-8');
        return json_encode($data);
    }
}
