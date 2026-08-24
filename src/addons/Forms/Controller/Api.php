<?php

namespace Forms\Controller;

/**
 * Routes bound at /forms/api.
 *
 * Extends App\Controller\Base, NOT App\Controller\App: the latter extends
 * Authenticated, whose initialize() reroutes anonymous requests to the login
 * screen - which would break the public receiver. Auth and CSRF are therefore
 * enforced explicitly per action below, mirroring what Authenticated does.
 */
class Api extends \App\Controller\Base {

    /**
     * PUBLIC. Receiver for the website's form posts.
     *
     *   POST /forms/api/submit
     *   { "form": "cotizar", "data": { "nombre": "...", "tel": "...", ... } }
     */
    public function submit() {

        $this->cors();

        if ($this->method() === 'OPTIONS') {
            return '';
        }

        if ($this->method() !== 'POST') {
            $this->app->response->status = 405;
            return $this->json(['success' => false, 'error' => 'Method not allowed.']);
        }

        $result = $this->helper('forms')->handleSubmission();

        $this->app->response->status = $result['status'];

        // A 503 means the anti-spam layer could not evaluate the rate limit;
        // tell honest clients when to come back.
        if (!empty($result['retryAfter'])) {
            header('Retry-After: '.(int)$result['retryAfter']);
        }

        unset($result['status'], $result['retryAfter']);

        return $this->json($result);
    }

    /**
     * GET /forms/api/list?form=cotizar&page=1&limit=25
     *
     * Returns items plus the column names for that form, so the screen can
     * render one real column per field.
     */
    public function list() {

        if (!$this->guard()) return false;

        return $this->json($this->helper('forms')->listSubmissions(
            $this->param('form', null),
            (int)$this->param('page', 1),
            (int)$this->param('limit', 25)
        ));
    }

    /**
     * GET /forms/api/forms  -> known forms with their submission counts.
     */
    public function forms() {

        if (!$this->guard()) return false;

        return $this->json($this->helper('forms')->forms());
    }

    /**
     * GET /forms/api/export?form=cotizar  ->  CSV download
     */
    public function export() {

        if (!$this->guard()) return false;

        $form = $this->param('form', null);
        $csv  = $this->helper('forms')->exportCsv($form);
        $name = 'submissions-'.($form ?: 'all').'-'.date('Ymd-His').'.csv';

        header('Content-Type: text/csv; charset=utf-8');
        header('Content-Disposition: attachment; filename="'.$name.'"');
        header('Content-Length: '.strlen($csv));

        return $csv;
    }

    /**
     * POST /forms/api/remove/{id}  (CSRF protected)
     */
    public function remove($id = null) {

        if (!$this->guard()) return false;

        if (!$this->hasValidCsrfToken()) {
            $this->app->response->status = 412;
            return $this->json(['success' => false, 'error' => 'Invalid CSRF token.']);
        }

        if (!$id) {
            $this->app->response->status = 400;
            return $this->json(['success' => false, 'error' => 'Missing id.']);
        }

        if (!$this->helper('forms')->remove($id)) {
            $this->app->response->status = 404;
            return $this->json(['success' => false, 'error' => 'Submission not found.']);
        }

        return $this->json(['success' => true]);
    }

    /**
     * POST /forms/api/read/{id}?read=0|1  (CSRF protected)
     */
    public function read($id = null) {

        if (!$this->guard()) return false;

        if (!$this->hasValidCsrfToken()) {
            $this->app->response->status = 412;
            return $this->json(['success' => false, 'error' => 'Invalid CSRF token.']);
        }

        $read = $this->param('read', '1') !== '0';

        if (!$id || !$this->helper('forms')->markRead($id, $read)) {
            $this->app->response->status = 404;
            return $this->json(['success' => false, 'error' => 'Submission not found.']);
        }

        return $this->json(['success' => true, 'read' => $read]);
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Requires a logged-in user holding forms/manage.
     *
     * Uses stop() rather than setting response->status and returning: a route
     * that returns false is treated as unhandled and the status is discarded.
     */
    protected function guard(): bool {

        $user = $this->helper('auth')->getUser();

        if (!$user) {
            $this->stop($this->json(['success' => false, 'error' => 'Authentication required.']), 401);
            return false;
        }

        // Authenticated::initialize() normally does this; acl reads from it.
        $this->app->set('user', $user);

        if (!$this->helper('acl')->isAllowed('forms/manage')) {
            $this->stop($this->json(['success' => false, 'error' => 'Permission denied.']), 403);
            return false;
        }

        return true;
    }

    /**
     * Same check App\Controller\Authenticated::hasValidCsrfToken() performs.
     */
    protected function hasValidCsrfToken(): bool {

        $token = $this->app->param('xcsrftoken', $this->app->request->headers['X-Csrf-Token'] ?? '');

        return $this->helper('csrf')->isValid('app.csrf', $token, true);
    }

    protected function json($data): string {
        header('Content-Type: application/json; charset=utf-8');
        return json_encode($data);
    }

    protected function method(): string {
        return strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
    }

    /**
     * Cross-origin policy of the public receiver. Fail-closed: when
     * the forms.allowed_origins config is not configured, no
     * Access-Control-Allow-Origin header is emitted at all - browsers then
     * block cross-origin reads, and a same-origin form post is unaffected.
     * Configure your site's origin(s), or explicitly opt into `['*']` if you
     * really want the receiver open to every origin.
     */
    protected function cors(): void {

        $configured = $this->helper('forms')->config('allowed_origins', null);
        $allowed    = is_array($configured) ? $configured : [];
        $origin     = $_SERVER['HTTP_ORIGIN'] ?? '';

        // Same-origin posts (and server-to-server calls) carry no Origin
        // header; CORS is enforced by browsers via the response headers below,
        // so the submission itself always proceeds normally.
        if (in_array('*', $allowed, true)) {
            header('Access-Control-Allow-Origin: *');
        } elseif ($origin && in_array($origin, $allowed, true)) {
            header('Access-Control-Allow-Origin: '.$origin);
            header('Vary: Origin');
        }

        header('Access-Control-Allow-Headers: Content-Type');
        header('Access-Control-Allow-Methods: POST, OPTIONS');
    }
}
