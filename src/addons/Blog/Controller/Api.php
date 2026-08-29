<?php

namespace Blog\Controller;

/**
 * Routes bound at /blog/api.
 *
 * Extends App\Controller\Base rather than App\Controller\App, mirroring Forms:
 * auth is enforced explicitly per action so the class never reroutes a request
 * to the login screen mid-XHR.
 *
 * Everything here is admin-only. The addon exposes no public read surface - the
 * site reads content through Cockpit's core REST API, which serves published
 * entries only.
 */
class Api extends \App\Controller\Base {

    /**
     * GET /blog/api/posts?blog=<id>
     *
     * Articles for the admin screen, with the byline resolved and the public
     * URL built when the site URL is configured.
     */
    public function posts() {

        if (!$this->guard()) return false;

        return [
            'success' => true,
            'posts'   => $this->helper('blog')->posts($this->param('blog', null)),
            'siteUrl' => $this->helper('blog')->siteUrl(),
        ];
    }

    /**
     * POST /blog/api/purge
     *
     * Asks the Go app to drop its cache. Saving an article already purges
     * automatically through the CachePurge addon; this is the manual escape
     * hatch for when the site and the CMS have drifted apart anyway.
     *
     * Delegates to the cachepurge helper so the endpoint, the token and the
     * failure logging stay in one place.
     */
    public function purge() {

        if (!$this->guard()) return false;

        if (!$this->hasValidCsrfToken()) {
            $this->stop(['success' => false, 'error' => 'Invalid CSRF token.'], 403);
            return false;
        }

        $purge = $this->app->helper('cachepurge') ?? null;

        if (!is_callable($purge)) {
            return [
                'success' => false,
                'error'   => 'The CachePurge addon is not installed, so this site has no cache to purge.',
            ];
        }

        $purge($this->param('model', null), $this->param('id', null));

        return ['success' => true];
    }

    // ---------------------------------------------------------------- helpers

    /**
     * Requires a logged-in user holding blog/manage.
     *
     * Uses stop() rather than setting response->status and returning: a route
     * that returns false is treated as unhandled and the status is discarded.
     */
    protected function guard(): bool {

        $user = $this->helper('auth')->getUser();

        if (!$user) {
            $this->stop(['success' => false, 'error' => 'Authentication required.'], 401);
            return false;
        }

        // Authenticated::initialize() normally does this; acl reads from it.
        $this->app->set('user', $user);

        if (!$this->helper('acl')->isAllowed('blog/manage')) {
            $this->stop(['success' => false, 'error' => 'Permission denied.'], 403);
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
}
