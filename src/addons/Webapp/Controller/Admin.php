<?php

namespace Webapp\Controller;

/**
 * Admin screen for Webapp settings and SEO management.
 */
class Admin extends \App\Controller\App {

    public function index() {

        if (!$this->isAllowed('webapp/manage')) {
            return $this->stop(401);
        }

        $webapp = $this->helper('webapp');

        // Creates models on first admin load.
        $webapp->ensureModels();

        return $this->render('webapp:views/index.php', [
            'webappConfig' => $webapp->getWebappConfig(),
            'webappFields' => $webapp->webappFields(),
            'seoPages'     => $webapp->seoPages(),
        ]);
    }

    /**
     * POST /webapp/purge - clears the application's page cache on request.
     *
     * Purging is a deliberate act now, not a side effect. Saving content used
     * to trigger it, and so did Cockpit's own "Clear cache" - which empties the
     * whole Redis database this CMS shares with its session and API-key
     * registries, so the app was told to re-render at the exact moment the CMS
     * could no longer authenticate it. Visitors got 502s from a routine
     * editorial action.
     *
     * A person pressing this knows what they are doing and can read what came
     * back, which is the difference that matters.
     */
    public function purge() {

        if (!$this->isAllowed('webapp/manage')) {
            return $this->stop(401);
        }

        if (!$this->hasValidCsrfToken()) {
            return $this->stop($this->json(['success' => false, 'error' => 'Invalid CSRF token.']), 403);
        }

        $result = $this->helper('webapp')->purgeNow();

        return $this->json($result);
    }
}
