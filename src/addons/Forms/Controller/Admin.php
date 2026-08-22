<?php

namespace Forms\Controller;

/**
 * Admin screen. Extends App\Controller\App so anonymous visitors are rerouted
 * to the login page and the panel layout is applied. All data is fetched by the
 * view from /forms/api/*.
 */
class Admin extends \App\Controller\App {

    public function index() {

        if (!$this->isAllowed('forms/manage')) {
            return $this->stop(401);
        }

        $forms = $this->helper('forms');

        // Makes a fresh install self-installing: the collections are created
        // the first time somebody opens the screen.
        $forms->ensureModels();

        // Retention policy enforces itself here: personal data older than the
        // configured window is cleared (rate-limited to once a day, so this
        // stays off the hot path).
        $forms->maintenance();

        return $this->render('forms:views/index.php', [
            'forms' => $forms->forms(),
        ]);
    }
}
