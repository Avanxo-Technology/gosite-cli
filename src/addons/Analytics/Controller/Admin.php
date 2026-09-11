<?php

namespace Analytics\Controller;

/**
 * Admin screen. Extends App\Controller\App so anonymous visitors are rerouted
 * to the login page and the panel layout is applied.
 */
class Admin extends \App\Controller\App {

    public function index() {

        if (!$this->isAllowed('analytics/manage')) {
            return $this->stop(401);
        }

        $analytics = $this->helper('analytics');
        $analytics->ensureModels();

        return $this->render('analytics:views/index.php', [
            'integrations' => $analytics->all(),
            // The banner's state gates every row on the screen, so the screen
            // has to be able to say so.
            'consent'      => $analytics->consent(),
            'reference'    => $analytics->providerReference(),
        ]);
    }
}
