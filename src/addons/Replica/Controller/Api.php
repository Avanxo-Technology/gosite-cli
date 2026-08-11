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
        return $this->json([
            'targets'     => $replica->targets(),
            'collections' => $replica->localModels(),
        ]);
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
            return $this->json(['success' => false, 'error' => $e->getMessage()]);
        }

        return $this->json(['success' => true, 'target' => $target]);
    }

    /**
     * POST /replica/api/remove/{id}  (CSRF)
     */
    public function remove($id = null) {

        if (!$this->guard() || !$this->csrf()) return false;

        if (!$id || !$this->helper('replica')->removeTarget($id)) {
            $this->app->response->status = 404;
            return $this->json(['success' => false, 'error' => 'Target not found.']);
        }

        return $this->json(['success' => true]);
    }

    /**
     * GET /replica/api/ping/{id} -> reachability + which transport applies
     */
    public function ping($id = null) {

        if (!$this->guard()) return false;

        $target = $this->helper('replica')->target((string)$id);

        if (!$target) {
            $this->app->response->status = 404;
            return $this->json(['ok' => false, 'error' => 'Target not found.']);
        }

        return $this->json($this->helper('replica')->client($target)->ping());
    }

    /**
     * POST /replica/api/run/{id}  (CSRF)
     * body: direction=push|pull, mode=mirror|merge, dryRun, verbose, model
     */
    public function run($id = null) {

        if (!$this->guard() || !$this->csrf()) return false;

        $replica = $this->helper('replica');
        $target  = $replica->target((string)$id);

        if (!$target) {
            $this->app->response->status = 404;
            return $this->json(['success' => false, 'error' => 'Target not found.']);
        }

        if (!$target->enabled) {
            $this->app->response->status = 412;
            return $this->json(['success' => false, 'error' => 'Target is disabled.']);
        }

        $direction = $this->param('direction', 'push') === 'pull' ? 'pull' : 'push';

        $options = [
            'mode'    => $this->param('mode', 'merge'),
            'dryRun'  => filter_var($this->param('dryRun', false), FILTER_VALIDATE_BOOLEAN),
            'verbose' => filter_var($this->param('verbose', false), FILTER_VALIDATE_BOOLEAN),
            'model'   => $this->param('model', null) ?: null,
        ];

        $result = $direction === 'pull'
            ? $replica->pull($target, $options)
            : $replica->push($target, $options);

        return $this->json(['success' => $result['errors'] === 0, 'result' => $result]);
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
            return $this->json(['success' => false, 'error' => 'Target not found.']);
        }

        return $this->json(['success' => true, 'enabled' => $target->enabled, 'target' => $target]);
    }

    /**
     * GET /replica/api/log?page=&target=
     */
    public function log() {

        if (!$this->guard()) return false;

        return $this->json($this->helper('replica')->log(
            (int)$this->param('page', 1),
            (int)$this->param('limit', 25),
            $this->param('target', null) ?: null
        ));
    }

    // ---------------------------------------------------------------- helpers

    protected function guard(): bool {

        $user = $this->helper('auth')->getUser();

        if (!$user) {
            $this->stop($this->json(['success' => false, 'error' => 'Authentication required.']), 401);
            return false;
        }

        // Authenticated::initialize() normally does this; acl reads from it.
        $this->app->set('user', $user);

        if (!$this->helper('acl')->isAllowed('replica/manage')) {
            $this->stop($this->json(['success' => false, 'error' => 'Permission denied.']), 403);
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

        $this->stop($this->json(['success' => false, 'error' => 'Invalid CSRF token.']), 412);

        return false;
    }

    protected function json($data): string {
        header('Content-Type: application/json; charset=utf-8');
        return json_encode($data);
    }
}
